import Foundation
import Network
import Observation
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

    public init() {}

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
            DispatchQueue.main.async {
                self?.forwardingState = newState
                if newState == .forwarding {
                    self?.connectionStatus = .forwarding
                    self?.capture?.isSuppressing = true
                } else if newState == .idle {
                    self?.connectionStatus = .connected
                    self?.capture?.isSuppressing = false
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
        let edge = EdgeDetector(
            trigger: EdgeTrigger(zone: .topRight),
            screenWidth: geometry.bounds.width,
            screenHeight: geometry.bounds.height,
            queue: queue
        )
        edgeDetector = edge

        edge.onEdgeEvent = { [weak self] event in
            if event == .triggered {
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
            stateMachine?.receivedActivated()
        case .deactivate:
            stateMachine?.receivedDeactivate()
        case .deactivated:
            stateMachine?.receivedDeactivated()
        case .pairAccept:
            DispatchQueue.main.async {
                self.connectionStatus = .connected
            }
        default:
            break
        }
    }

    // MARK: - Receiver Setup (incoming connection)

    private func handleIncomingConnection(_ conn: NWConnection) {
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
            self.isInjecting = false
            self.sendDeactivateOnIncoming()
        }

        framed.onState = { [weak self] state in
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

    private func handleReceiverFrame(_ data: Data) {
        guard let env = try? InputShareCodec.decodeEnvelope(data) else { return }
        let geometry = ScreenGeometry.mainDisplay()

        switch env.messageType {
        case .activate:
            isInjecting = true
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
            }

        case .inputEvent:
            guard isInjecting else { return }
            guard let input = try? InputShareCodec.decodePayload(InputEvent.self, from: env.payload) else { return }
            injector?.inject(input)

            if input.kind == .mouseMove, let pos = input.normalizedPosition {
                let pt = geometry.denormalize(x: pos.x, y: pos.y)
                returnEdgeDetector?.update(position: pt)
            }

        case .deactivate:
            isInjecting = false
            DispatchQueue.main.async {
                self.connectionStatus = .connected
                self.forwardingState = .idle
            }
            // Send deactivated ack
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
