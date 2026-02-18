import Foundation
import Network
import Observation
import ApplicationServices
import InputShareShared
import InputShareTransport
import InputShareCapture
import InputShareInjection
import InputShareEdge
import InputShareDiscovery

public enum ConnectionStatus: String {
    case disconnected = "Disconnected"
    case connecting = "Connecting..."
    case connected = "Connected"
    case forwarding = "Forwarding"
}

@Observable
public final class AppState {
    public var connectionStatus: ConnectionStatus = .disconnected
    public var forwardingState: ForwardingState = .idle
    public var discoveredDevices: [DiscoveredDevice] = []
    public var pairedDeviceName: String?

    private let browser = BonjourBrowser()
    private var advertiser: BonjourAdvertiser?
    private var capture: EventTapCapture?
    private var injector: InputInjector?
    private var edgeDetector: EdgeDetector?
    private var returnEdgeDetector: EdgeDetector?
    private var stateMachine: ForwardingStateMachine?
    private var framedConnection: NWFramedConnection?
    private var incomingFramed: NWFramedConnection?
    private var isInjecting = false

    private let queue = DispatchQueue(label: "inputshare.app")
    private let seq = Sequencer()
    private let deviceId = Host.current().localizedName ?? UUID().uuidString

    public init() {
        ensureAccessibility()
    }

    private func ensureAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(opts)
        print("[App] Accessibility trusted: \(trusted)")
    }

    // MARK: - Discovery

    public func startDiscovery() {
        browser.start()
        startAdvertiser()
    }

    public func stopDiscovery() {
        browser.stop()
        advertiser?.stop()
    }

    private func startAdvertiser() {
        let adv = BonjourAdvertiser(queue: queue)
        adv.onReady = {
            print("[App] Bonjour advertiser ready")
        }
        adv.onNewConnection = { [weak self] conn in
            self?.handleIncomingConnection(conn)
        }
        do {
            try adv.start()
            advertiser = adv
        } catch {
            print("[App] Failed to start advertiser: \(error)")
        }
    }

    // MARK: - Connect (as sender)

    public func connectTo(device: DiscoveredDevice) {
        connectionStatus = .connecting
        pairedDeviceName = device.name

        let conn = NWConnection(to: device.endpoint, using: .tcp)
        let framed = NWFramedConnection(connection: conn, queue: queue)
        framedConnection = framed

        setupSenderStateMachine()

        framed.onState = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    self?.connectionStatus = .connected
                    print("[App] Connected to \(device.name)")
                    self?.startSenderCapture()
                case .failed, .cancelled:
                    self?.connectionStatus = .disconnected
                    self?.pairedDeviceName = nil
                default:
                    break
                }
            }
        }

        framed.onFrame = { [weak self] data in
            self?.handleSenderFrame(data)
        }

        framed.start()
    }

    // MARK: - Disconnect

    public func disconnect() {
        capture?.stop()
        capture = nil
        framedConnection?.cancel()
        framedConnection = nil
        incomingFramed?.cancel()
        incomingFramed = nil
        stateMachine?.reset()
        stateMachine = nil
        edgeDetector = nil
        returnEdgeDetector = nil
        isInjecting = false
        DispatchQueue.main.async {
            self.connectionStatus = .disconnected
            self.forwardingState = .idle
            self.pairedDeviceName = nil
        }
    }

    // MARK: - Sender Setup

    private func setupSenderStateMachine() {
        let sm = ForwardingStateMachine(queue: queue)
        stateMachine = sm

        sm.onStateChange = { [weak self] newState in
            guard let self else { return }
            print("[App] Forwarding state -> \(newState.rawValue)")

            if newState == .forwarding {
                // Virtual cursor starts at top-left (maps to receiver's top-left)
                self.capture?.startSuppressing(virtualStart: CGPoint(x: 20, y: 20))
            } else if newState == .idle {
                let wasSuppressing = self.capture?.isSuppressing == true
                self.capture?.stopSuppressing()

                if wasSuppressing {
                    // Returning from forwarding — place cursor near top-right
                    let geo = ScreenGeometry.mainDisplay()
                    let returnPos = CGPoint(x: geo.bounds.width - 20, y: 20)
                    CGWarpMouseCursorPosition(returnPos)
                    // Arm edge so it doesn't re-trigger until user leaves the corner
                    self.edgeDetector?.armAfterEntry()
                }
            }

            DispatchQueue.main.async {
                self.forwardingState = newState
                if newState == .forwarding {
                    self.connectionStatus = .forwarding
                } else if newState == .idle {
                    self.connectionStatus = .connected
                }
            }
        }

        sm.onShouldSendActivate = { [weak self] in
            self?.sendActivate()
        }

        sm.onShouldSendDeactivate = { [weak self] in
            self?.sendDeactivate()
        }
    }

    private func startSenderCapture() {
        let geometry = ScreenGeometry.mainDisplay()
        print("[App] Screen bounds: \(geometry.bounds)")

        let edge = EdgeDetector(
            trigger: EdgeTrigger(zone: .topRight),
            screenWidth: geometry.bounds.width,
            screenHeight: geometry.bounds.height,
            queue: queue
        )
        edgeDetector = edge

        edge.onEdgeEvent = { [weak self] event in
            if event == .triggered {
                print("[App] Edge triggered — top-right corner")
                self?.stateMachine?.edgeTriggered()
            }
        }

        let cap = EventTapCapture(handler: { [weak self] input in
            guard let self, self.stateMachine?.state == .forwarding else { return }
            self.sendInputEvent(input)
        }, geometry: geometry)

        cap.onRawMouseMove = { [weak self] point in
            self?.edgeDetector?.update(position: point)
        }

        capture = cap
        do {
            try cap.start()
            print("[App] Capture started")
        } catch {
            print("[App] Failed to start capture: \(error)")
        }
    }

    private func handleSenderFrame(_ data: Data) {
        guard let env = try? InputShareCodec.decodeEnvelope(data) else { return }
        switch env.messageType {
        case .activated:
            print("[App] Received activated ack from receiver")
            stateMachine?.receivedActivated()
        case .deactivate:
            print("[App] Received deactivate from receiver — returning control")
            stateMachine?.receivedDeactivate()
        case .deactivated:
            stateMachine?.receivedDeactivated()
        default:
            break
        }
    }

    // MARK: - Receiver Setup (incoming connection)

    private func handleIncomingConnection(_ conn: NWConnection) {
        print("[App] Incoming connection from \(conn.endpoint)")
        let framed = NWFramedConnection(connection: conn, queue: queue)
        incomingFramed = framed

        let geometry = ScreenGeometry.mainDisplay()
        let injector = InputInjector(geometry: geometry)
        self.injector = injector

        let returnEdge = EdgeDetector(
            trigger: EdgeTrigger(zone: .topLeft),
            screenWidth: geometry.bounds.width,
            screenHeight: geometry.bounds.height,
            queue: queue
        )
        returnEdgeDetector = returnEdge

        returnEdge.onEdgeEvent = { [weak self] event in
            guard let self, self.isInjecting, event == .triggered else { return }
            print("[App] Return edge triggered — top-left corner")
            self.isInjecting = false
            self.sendDeactivateOnIncoming()
        }

        framed.onState = { [weak self] state in
            print("[App] Incoming connection state: \(state)")
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    self?.connectionStatus = .connected
                    self?.pairedDeviceName = "Remote"
                case .failed, .cancelled:
                    if self?.framedConnection == nil {
                        self?.connectionStatus = .disconnected
                        self?.pairedDeviceName = nil
                    }
                default:
                    break
                }
            }
        }

        framed.onFrame = { [weak self] data in
            self?.handleReceiverFrame(data)
        }

        framed.start()
    }

    private var receiverEventCount = 0

    private func handleReceiverFrame(_ data: Data) {
        guard let env = try? InputShareCodec.decodeEnvelope(data) else {
            print("[App] Failed to decode envelope")
            return
        }
        let geometry = ScreenGeometry.mainDisplay()

        switch env.messageType {
        case .activate:
            print("[App] Received activate — warping cursor to top-left, now injecting")
            isInjecting = true
            receiverEventCount = 0

            // Place cursor at top-left (sender is forwarding from top-right)
            CGWarpMouseCursorPosition(CGPoint(x: 20, y: 20))
            CGAssociateMouseAndMouseCursorPosition(1)

            // Arm return edge — cursor must leave the corner before return can trigger
            returnEdgeDetector?.armAfterEntry()

            DispatchQueue.main.async {
                self.connectionStatus = .forwarding
                self.forwardingState = .forwarding
            }
            // Send activated ack
            let ack = MessageEnvelope(
                protocolVersion: InputShareCodec.protocolVersion,
                messageType: .activated,
                sequenceNumber: seq.next(),
                monotonicTimeNs: MonotonicClock.nowNs(),
                sourceDeviceId: deviceId,
                payload: Data()
            )
            if let ackData = try? InputShareCodec.encodeEnvelope(ack) {
                incomingFramed?.sendFrame(ackData)
                print("[App] Sent activated ack")
            }

        case .inputEvent:
            guard isInjecting else { return }
            guard let input = try? InputShareCodec.decodePayload(InputEvent.self, from: env.payload) else {
                print("[App] Failed to decode input event")
                return
            }
            receiverEventCount += 1
            if receiverEventCount <= 5 || receiverEventCount % 100 == 0 {
                if input.kind == .mouseMove, let pos = input.normalizedPosition {
                    let pt = geometry.denormalize(x: pos.x, y: pos.y)
                    print("[App] Injecting mouseMove #\(receiverEventCount) -> (\(Int(pt.x)), \(Int(pt.y)))")
                } else {
                    print("[App] Injecting \(input.kind.rawValue) #\(receiverEventCount)")
                }
            }
            injector?.inject(input)

            if input.kind == .mouseMove, let pos = input.normalizedPosition {
                let pt = geometry.denormalize(x: pos.x, y: pos.y)
                returnEdgeDetector?.update(position: pt)
            }

        case .deactivate:
            print("[App] Received deactivate — stopping injection")
            isInjecting = false
            DispatchQueue.main.async {
                self.connectionStatus = .connected
                self.forwardingState = .idle
            }
            let ack = MessageEnvelope(
                protocolVersion: InputShareCodec.protocolVersion,
                messageType: .deactivated,
                sequenceNumber: seq.next(),
                monotonicTimeNs: MonotonicClock.nowNs(),
                sourceDeviceId: deviceId,
                payload: Data()
            )
            if let ackData = try? InputShareCodec.encodeEnvelope(ack) {
                incomingFramed?.sendFrame(ackData)
            }

        default:
            break
        }
    }

    // MARK: - Message Sending

    private func sendInputEvent(_ input: InputEvent) {
        let payload = (try? InputShareCodec.encodePayload(input)) ?? Data()
        let env = MessageEnvelope(
            protocolVersion: InputShareCodec.protocolVersion,
            messageType: .inputEvent,
            sequenceNumber: seq.next(),
            monotonicTimeNs: MonotonicClock.nowNs(),
            sourceDeviceId: deviceId,
            payload: payload
        )
        if let data = try? InputShareCodec.encodeEnvelope(env) {
            framedConnection?.sendFrame(data)
        }
    }

    private func sendActivate() {
        print("[App] Sending activate to receiver...")
        let payload = (try? InputShareCodec.encodePayload(ActivatePayload(normalizedPosition: NormalizedPoint(x: 1.0, y: 0.0)))) ?? Data()
        let env = MessageEnvelope(
            protocolVersion: InputShareCodec.protocolVersion,
            messageType: .activate,
            sequenceNumber: seq.next(),
            monotonicTimeNs: MonotonicClock.nowNs(),
            sourceDeviceId: deviceId,
            payload: payload
        )
        if let data = try? InputShareCodec.encodeEnvelope(env) {
            framedConnection?.sendFrame(data)
        }
    }

    private func sendDeactivate() {
        print("[App] Sending deactivate to receiver...")
        let env = MessageEnvelope(
            protocolVersion: InputShareCodec.protocolVersion,
            messageType: .deactivate,
            sequenceNumber: seq.next(),
            monotonicTimeNs: MonotonicClock.nowNs(),
            sourceDeviceId: deviceId,
            payload: Data()
        )
        if let data = try? InputShareCodec.encodeEnvelope(env) {
            framedConnection?.sendFrame(data)
        }
    }

    private func sendDeactivateOnIncoming() {
        print("[App] Sending deactivate (return) to sender...")
        let env = MessageEnvelope(
            protocolVersion: InputShareCodec.protocolVersion,
            messageType: .deactivate,
            sequenceNumber: seq.next(),
            monotonicTimeNs: MonotonicClock.nowNs(),
            sourceDeviceId: deviceId,
            payload: Data()
        )
        if let data = try? InputShareCodec.encodeEnvelope(env) {
            incomingFramed?.sendFrame(data)
        }
        DispatchQueue.main.async {
            self.connectionStatus = .connected
            self.forwardingState = .idle
        }
    }

    // Update devices from browser
    public func refreshDevices() {
        discoveredDevices = browser.devices
    }
}

final class Sequencer: @unchecked Sendable {
    private var n: UInt64 = 0
    func next() -> UInt64 { n += 1; return n }
}
