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
    public var isNearEdge: Bool = false

    /// Called on the main queue when edge proximity changes (for managing glow overlay)
    public var onNearEdgeChanged: ((Bool) -> Void)?

    private let browser = BonjourBrowser()
    private var advertiser: BonjourAdvertiser?
    private var capture: EventTapCapture?          // sender-side: captures + forwards events
    private var receiverTap: EventTapCapture?       // receiver-side: suppresses local input
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

    // Y coordinate (in screen coords) where cursor crossed the edge
    private var crossingPosition: CGPoint = .zero

    // Receiver cursor tracking — apply deltas instead of denormalizing
    private var receiverCursorPos: CGPoint = .zero
    private var receiverGeometry: ScreenGeometry?

    // Mouse move coalescing — only send latest position at fixed interval
    private var pendingMouseMove: InputEvent?
    private var coalesceTimer: DispatchSourceTimer?
    private static let coalesceInterval: TimeInterval = 0.008  // ~125 Hz

    public init() {
        ensureAccessibility()
    }

    /// Immediately restore local mouse/keyboard control regardless of current role.
    /// Safe to call from either sender or receiver side, or even when not suppressing.
    private func restoreLocalControl() {
        print("[App] Restoring local control")
        // Sender side
        stopCoalesceTimer()
        capture?.stopSuppressing()
        capture?.stop()
        capture = nil
        stateMachine?.reset()
        stateMachine = nil
        edgeDetector = nil

        // Receiver side
        isInjecting = false
        receiverTap?.stopSuppressing()
        receiverTap?.stop()
        receiverTap = nil
        returnEdgeDetector = nil
        injector = nil
        receiverGeometry = nil

        // Connections
        framedConnection?.cancel()
        framedConnection = nil
        incomingFramed?.cancel()
        incomingFramed = nil

        // Failsafe — ensure HID is re-associated no matter what
        CGAssociateMouseAndMouseCursorPosition(1)
        CGDisplayShowCursor(CGMainDisplayID())

        DispatchQueue.main.async {
            self.connectionStatus = .disconnected
            self.forwardingState = .idle
            self.pairedDeviceName = nil
        }
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

        let conn = NWConnection(to: device.endpoint, using: NWTransport.tcpParameters)
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
                    print("[App] Sender connection lost — restoring local control")
                    self?.restoreLocalControl()
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
        restoreLocalControl()
    }

    // MARK: - Sender Setup

    private func setupSenderStateMachine() {
        let sm = ForwardingStateMachine(queue: queue)
        stateMachine = sm

        sm.onStateChange = { [weak self] newState in
            guard let self else { return }
            print("[App] Forwarding state -> \(newState.rawValue)")

            if newState == .forwarding {
                // Virtual cursor starts at receiver's left edge, same Y as crossing
                let geo = ScreenGeometry.allDisplays()
                let startPos = CGPoint(x: geo.bounds.minX, y: self.crossingPosition.y)
                self.capture?.startSuppressing(virtualStart: startPos)
                self.startCoalesceTimer()
            } else if newState == .idle {
                let wasSuppressing = self.capture?.isSuppressing == true
                self.capture?.stopSuppressing()
                self.stopCoalesceTimer()

                if wasSuppressing {
                    // Returning — place cursor at right edge at the return Y
                    let geo = ScreenGeometry.allDisplays()
                    let returnPos = CGPoint(x: geo.bounds.maxX - 2, y: self.crossingPosition.y)
                    CGWarpMouseCursorPosition(returnPos)
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
        let geometry = ScreenGeometry.allDisplays(log: true)
        print("[App] Screen bounds (all displays): \(geometry.bounds)")

        let edge = EdgeDetector(
            trigger: EdgeTrigger(zone: .right, dwellTime: 0.1),
            screenBounds: geometry.bounds,
            queue: queue
        )
        edgeDetector = edge

        edge.onEdgeEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .entered:
                DispatchQueue.main.async {
                    self.isNearEdge = true
                    self.onNearEdgeChanged?(true)
                }
            case .triggered(let pos):
                DispatchQueue.main.async {
                    self.isNearEdge = false
                    self.onNearEdgeChanged?(false)
                }
                print("[App] Right edge triggered at Y=\(Int(pos.y))")
                self.crossingPosition = pos
                self.stateMachine?.edgeTriggered()
            case .exited:
                DispatchQueue.main.async {
                    self.isNearEdge = false
                    self.onNearEdgeChanged?(false)
                }
            }
        }

        let cap = EventTapCapture(handler: { [weak self] input in
            guard let self, self.stateMachine?.state == .forwarding else { return }
            if input.kind == .mouseMove {
                // Coalesce mouse moves — accumulate deltas so none are lost
                if var pending = self.pendingMouseMove {
                    pending.mouseDeltaX = (pending.mouseDeltaX ?? 0) + (input.mouseDeltaX ?? 0)
                    pending.mouseDeltaY = (pending.mouseDeltaY ?? 0) + (input.mouseDeltaY ?? 0)
                    pending.normalizedPosition = input.normalizedPosition
                    pending.flags = input.flags
                    self.pendingMouseMove = pending
                } else {
                    self.pendingMouseMove = input
                }
            } else {
                // Flush any pending mouse move before sending non-move events
                if let pending = self.pendingMouseMove {
                    self.pendingMouseMove = nil
                    self.sendInputEvent(pending)
                }
                self.sendInputEvent(input)
            }
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
            // Read return Y from receiver
            if let deactPayload = try? InputShareCodec.decodePayload(DeactivatePayload.self, from: env.payload) {
                // Denormalize return Y against the right-edge display
                let geo = ScreenGeometry.allDisplays()
                let edgeDisplay = geo.displayAtRightEdge()
                let returnY = edgeDisplay.minY + CGFloat(deactPayload.normalizedY) * edgeDisplay.height
                crossingPosition = CGPoint(x: geo.bounds.maxX, y: returnY)
                print("[App] Received deactivate from receiver — returning at Y=\(Int(returnY))")
            } else {
                print("[App] Received deactivate from receiver — returning control")
            }
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

        let geometry = ScreenGeometry.allDisplays(log: true)
        self.receiverGeometry = geometry
        let injector = InputInjector(geometry: geometry)
        self.injector = injector
        print("[App] Receiver screen bounds (all displays): \(geometry.bounds)")

        // Create event tap on receiver to suppress local input while being controlled
        let tap = EventTapCapture(handler: { _ in }, geometry: geometry)
        do {
            try tap.start()
            receiverTap = tap
            print("[App] Receiver event tap started")
        } catch {
            print("[App] Failed to start receiver event tap: \(error)")
        }

        let returnEdge = EdgeDetector(
            trigger: EdgeTrigger(zone: .left, dwellTime: 0.1),
            screenBounds: geometry.bounds,
            queue: queue
        )
        returnEdgeDetector = returnEdge

        returnEdge.onEdgeEvent = { [weak self] event in
            guard let self, self.isInjecting else { return }
            if case .triggered(let pos) = event {
                print("[App] Left edge triggered at Y=\(Int(pos.y)) — returning control")
                self.crossingPosition = pos
                self.isInjecting = false
                self.sendDeactivateOnIncoming()
            }
        }

        framed.onState = { [weak self] state in
            print("[App] Incoming connection state: \(state)")
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    self?.connectionStatus = .connected
                    self?.pairedDeviceName = "Remote"
                case .failed, .cancelled:
                    print("[App] Receiver connection lost — restoring local control")
                    self?.restoreLocalControl()
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
    private var receiverButtonsDown: Set<MouseButton> = []

    private func handleReceiverFrame(_ data: Data) {
        guard let env = try? InputShareCodec.decodeEnvelope(data) else {
            print("[App] Failed to decode envelope")
            return
        }
        guard let geometry = receiverGeometry else { return }

        switch env.messageType {
        case .activate:
            isInjecting = true
            receiverEventCount = 0
            receiverButtonsDown.removeAll()

            // Place cursor on the left-edge display at proportional Y
            let activatePayload = try? InputShareCodec.decodePayload(ActivatePayload.self, from: env.payload)
            let normY = activatePayload?.normalizedPosition.y ?? 0.5
            let leftDisplay = geometry.displayAtLeftEdge()
            let cursorY = leftDisplay.minY + CGFloat(normY) * leftDisplay.height
            let startPos = CGPoint(x: leftDisplay.minX + 2, y: cursorY)
            receiverCursorPos = startPos
            print("[App] Received activate — placing cursor at left edge Y=\(Int(cursorY)) (leftDisplay=\(Int(leftDisplay.width))x\(Int(leftDisplay.height)) at Y=\(Int(leftDisplay.minY)))")

            // Suppress local trackpad/mouse — keep cursor visible (controlled remotely)
            receiverTap?.startSuppressing(virtualStart: .zero, hideCursor: false)
            CGWarpMouseCursorPosition(startPos)

            // Arm return edge — cursor must leave the edge before return can trigger
            returnEdgeDetector?.armAfterEntry()

            DispatchQueue.main.async {
                self.connectionStatus = .forwarding
                self.forwardingState = .forwarding
            }
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

            if input.kind == .mouseMove {
                // Apply raw pixel deltas — no normalization/denormalization needed
                if let dx = input.mouseDeltaX, let dy = input.mouseDeltaY {
                    receiverCursorPos.x += CGFloat(dx)
                    receiverCursorPos.y += CGFloat(dy)
                    // Clamp to virtual screen bounds
                    let b = geometry.bounds
                    receiverCursorPos.x = max(b.minX, min(receiverCursorPos.x, b.maxX))
                    receiverCursorPos.y = max(b.minY, min(receiverCursorPos.y, b.maxY))
                }

                if receiverEventCount <= 5 || receiverEventCount % 100 == 0 {
                    print("[App] Injecting mouseMove #\(receiverEventCount) -> (\(Int(receiverCursorPos.x)), \(Int(receiverCursorPos.y)))")
                }

                // Pick the right event type: dragged when a button is held, moved otherwise
                let moveType: CGEventType
                let moveButton: CGMouseButton
                if receiverButtonsDown.contains(.left) {
                    moveType = .leftMouseDragged; moveButton = .left
                } else if receiverButtonsDown.contains(.right) {
                    moveType = .rightMouseDragged; moveButton = .right
                } else if receiverButtonsDown.contains(.other) {
                    moveType = .otherMouseDragged; moveButton = .center
                } else {
                    moveType = .mouseMoved; moveButton = .left
                }

                // Warp cursor and post synthetic event
                CGWarpMouseCursorPosition(receiverCursorPos)
                if let cg = CGEvent(mouseEventSource: nil, mouseType: moveType, mouseCursorPosition: receiverCursorPos, mouseButton: moveButton) {
                    cg.flags = CGEventFlags(rawValue: UInt64(input.flags))
                    cg.setIntegerValueField(.eventSourceUserData, value: Int64(InputShareInjectionMarker.value))
                    cg.post(tap: .cghidEventTap)
                }

                returnEdgeDetector?.update(position: receiverCursorPos)
            } else if input.kind == .mouseButton {
                // Track button state for drag event generation
                if let button = input.button, let state = input.buttonState {
                    if state == .down {
                        receiverButtonsDown.insert(button)
                    } else {
                        receiverButtonsDown.remove(button)
                    }
                }
                if receiverEventCount <= 5 || receiverEventCount % 100 == 0 {
                    print("[App] Injecting \(input.kind.rawValue) #\(receiverEventCount)")
                }
                injector?.inject(input)
            } else {
                // Non-move events: use injector as before
                if receiverEventCount <= 5 || receiverEventCount % 100 == 0 {
                    print("[App] Injecting \(input.kind.rawValue) #\(receiverEventCount)")
                }
                injector?.inject(input)
            }

        case .deactivate:
            print("[App] Received deactivate — restoring local input")
            isInjecting = false
            receiverTap?.stopSuppressing()
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

    // MARK: - Mouse Move Coalescing

    private func startCoalesceTimer() {
        stopCoalesceTimer()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: Self.coalesceInterval)
        timer.setEventHandler { [weak self] in
            guard let self, let pending = self.pendingMouseMove else { return }
            self.pendingMouseMove = nil
            self.sendInputEvent(pending)
        }
        coalesceTimer = timer
        timer.resume()
    }

    private func stopCoalesceTimer() {
        coalesceTimer?.cancel()
        coalesceTimer = nil
        // Flush any remaining pending move
        if let pending = pendingMouseMove {
            pendingMouseMove = nil
            sendInputEvent(pending)
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
        // Normalize Y against the display at the right edge, not the full virtual screen.
        // This ensures the Y maps correctly regardless of how the other machine's displays are arranged.
        let geo = ScreenGeometry.allDisplays()
        let edgeDisplay = geo.displayAtRightEdge()
        let normY = (crossingPosition.y - edgeDisplay.minY) / edgeDisplay.height
        print("[App] Sending activate to receiver (normY=\(String(format: "%.3f", normY)), edgeDisplay=\(Int(edgeDisplay.width))x\(Int(edgeDisplay.height)))...")
        let payload = (try? InputShareCodec.encodePayload(ActivatePayload(normalizedPosition: NormalizedPoint(x: 0.0, y: normY)))) ?? Data()
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
        // Normalize return Y against the left-edge display
        let geo = receiverGeometry ?? ScreenGeometry.allDisplays()
        let leftDisplay = geo.displayAtLeftEdge()
        let normY = (crossingPosition.y - leftDisplay.minY) / leftDisplay.height
        print("[App] Sending deactivate (return) to sender (normY=\(String(format: "%.3f", normY))), restoring local input...")
        receiverTap?.stopSuppressing()
        let payload = (try? InputShareCodec.encodePayload(DeactivatePayload(normalizedY: normY))) ?? Data()
        let env = MessageEnvelope(
            protocolVersion: InputShareCodec.protocolVersion,
            messageType: .deactivate,
            sequenceNumber: seq.next(),
            monotonicTimeNs: MonotonicClock.nowNs(),
            sourceDeviceId: deviceId,
            payload: payload
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
        let localName = Host.current().localizedName ?? ""
        discoveredDevices = browser.devices.filter { $0.name != localName }
    }
}

final class Sequencer: @unchecked Sendable {
    private var n: UInt64 = 0
    func next() -> UInt64 { n += 1; return n }
}
