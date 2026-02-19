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
    /// 0.0 (far) → 1.0 (at edge). Drives the progressive edge glow overlay.
    public var edgeProximity: CGFloat = 0
    /// Derived: true when cursor is close enough to show portal warning in UI.
    public var isNearEdge: Bool { edgeProximity > 0.05 }

    /// Called on main queue with (proximity, isRightEdge, edgeX) to drive glow panel.
    /// edgeX is the X coordinate of the screen boundary edge (used to find the correct NSScreen).
    public var onEdgeGlowUpdate: ((_ proximity: CGFloat, _ rightEdge: Bool, _ edgeX: CGFloat) -> Void)?

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

    // Position and display where cursor crossed the edge
    private var crossingPosition: CGPoint = .zero
    private var crossingDisplayRect: CGRect = .zero
    private var senderGeometry: ScreenGeometry?

    // Receiver cursor tracking — apply deltas instead of denormalizing
    private var receiverCursorPos: CGPoint = .zero
    private var receiverGeometry: ScreenGeometry?

    // Mouse move coalescing — only send latest position at fixed interval
    private var pendingMouseMove: InputEvent?
    private var pendingScroll: InputEvent?
    private var coalesceTimer: DispatchSourceTimer?
    private static let coalesceInterval: TimeInterval = 0.004  // ~250 Hz

    // Edge proximity tracking (drives progressive glow)
    private var _senderProximity: CGFloat = 0
    private var _receiverProximity: CGFloat = 0
    private static let glowZoneFraction: CGFloat = 0.05  // 5% of edge-display width

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
        senderGeometry = nil

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

        // Reset edge proximity
        _senderProximity = 0
        _receiverProximity = 0

        // Failsafe — ensure HID is re-associated no matter what
        CGAssociateMouseAndMouseCursorPosition(1)
        CGDisplayShowCursor(CGMainDisplayID())

        DispatchQueue.main.async {
            self.edgeProximity = 0
            self.onEdgeGlowUpdate?(0, true, 0)
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
                    // Returning — place cursor at the right edge of the display where we originally crossed
                    let returnPos = CGPoint(x: self.crossingDisplayRect.maxX - 2, y: self.crossingPosition.y)
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
        senderGeometry = geometry
        print("[App] Screen bounds (all displays): \(geometry.bounds)")

        let edge = EdgeDetector(
            trigger: EdgeTrigger(zone: .right, dwellTime: 0.1),
            screenBounds: geometry.bounds,
            displayRects: geometry.displayRects,
            queue: queue
        )
        edgeDetector = edge

        edge.onEdgeEvent = { [weak self] event in
            if case .triggered(let pos) = event {
                let display = geometry.displayContaining(point: pos)
                print("[App] Right edge triggered at Y=\(Int(pos.y)) on display \(Int(display.width))x\(Int(display.height))")
                self?.crossingPosition = pos
                self?.crossingDisplayRect = display
                self?.stateMachine?.edgeTriggered()
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
            } else if input.kind == .scroll {
                // Coalesce scroll events — accumulate deltas
                if var pending = self.pendingScroll, let newScroll = input.scroll {
                    let oldDx = pending.scroll?.deltaX ?? 0
                    let oldDy = pending.scroll?.deltaY ?? 0
                    pending.scroll = ScrollDelta(deltaX: oldDx + newScroll.deltaX, deltaY: oldDy + newScroll.deltaY)
                    pending.flags = input.flags
                    self.pendingScroll = pending
                } else {
                    self.pendingScroll = input
                }
            } else {
                // Flush pending mouse move and scroll before sending non-move events
                if let pending = self.pendingMouseMove {
                    self.pendingMouseMove = nil
                    self.sendInputEvent(pending)
                }
                if let pending = self.pendingScroll {
                    self.pendingScroll = nil
                    self.sendInputEvent(pending)
                }
                self.sendInputEvent(input)
            }
        }, queue: queue, geometry: geometry)

        cap.onRawMouseMove = { [weak self] point in
            guard let self else { return }
            self.edgeDetector?.update(position: point)

            // Progressive edge glow — distance to right boundary of cursor's display
            let suppressing = self.capture?.isSuppressing ?? false
            let cursorDisplay = geometry.displayContaining(point: point)
            let glowZone = cursorDisplay.width * Self.glowZoneFraction
            let dist = suppressing ? CGFloat.infinity : geometry.distanceToRightBoundary(from: point)
            let prox = max(0, min(1, 1 - dist / glowZone))
            if abs(prox - self._senderProximity) > 0.01 || (prox == 0) != (self._senderProximity == 0) {
                self._senderProximity = prox
                DispatchQueue.main.async {
                    self.edgeProximity = prox
                    self.onEdgeGlowUpdate?(prox, true, cursorDisplay.maxX)
                }
            }
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
            // Denormalize return Y against entire virtual screen, find the right-boundary display
            if let deactPayload = try? InputShareCodec.decodePayload(DeactivatePayload.self, from: env.payload) {
                let geo = senderGeometry ?? ScreenGeometry.allDisplays()
                let returnY = geo.bounds.minY + CGFloat(deactPayload.normalizedY) * geo.bounds.height
                if let returnDisplay = geo.displayAtRightBoundary(forY: returnY) {
                    crossingDisplayRect = returnDisplay
                    let clampedY = min(max(returnY, returnDisplay.minY + 1), returnDisplay.maxY - 1)
                    crossingPosition = CGPoint(x: returnDisplay.maxX, y: clampedY)
                } else {
                    crossingPosition = CGPoint(x: crossingDisplayRect.maxX, y: returnY)
                }
                print("[App] Received deactivate from receiver — returning at Y=\(Int(crossingPosition.y)) on display \(Int(crossingDisplayRect.width))x\(Int(crossingDisplayRect.height))")
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
        // Tear down any existing receiver state to prevent dangling event tap pointers
        // (Bonjour can deliver duplicate connections via IPv4 + IPv6)
        if incomingFramed != nil {
            print("[App] Replacing existing incoming connection")
            isInjecting = false
            receiverTap?.stopSuppressing()
            receiverTap?.stop()
            receiverTap = nil
            incomingFramed?.cancel()
            incomingFramed = nil
            returnEdgeDetector = nil
            injector = nil
        }

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
            displayRects: geometry.displayRects,
            queue: queue
        )
        returnEdgeDetector = returnEdge

        returnEdge.onEdgeEvent = { [weak self] event in
            guard let self, self.isInjecting else { return }
            if case .triggered(let pos) = event {
                let display = geometry.displayContaining(point: pos)
                print("[App] Left edge triggered at Y=\(Int(pos.y)) on display \(Int(display.width))x\(Int(display.height)) — returning control")
                self.crossingPosition = pos
                self.crossingDisplayRect = display
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

            // Denormalize Y against entire virtual screen, then find the left-boundary display at that Y
            let activatePayload = try? InputShareCodec.decodePayload(ActivatePayload.self, from: env.payload)
            let normY = activatePayload?.normalizedPosition.y ?? 0.5
            let globalY = geometry.bounds.minY + CGFloat(normY) * geometry.bounds.height
            let entryDisplay = geometry.displayAtLeftBoundary(forY: globalY) ?? geometry.displayAtLeftEdge()
            // Clamp Y within the entry display so cursor doesn't land outside its bounds
            let cursorY = min(max(globalY, entryDisplay.minY + 1), entryDisplay.maxY - 1)
            let startPos = CGPoint(x: entryDisplay.minX + 2, y: cursorY)
            receiverCursorPos = startPos
            print("[App] Received activate — placing cursor at left edge Y=\(Int(cursorY)) (entryDisplay=\(Int(entryDisplay.width))x\(Int(entryDisplay.height)) at Y=\(Int(entryDisplay.minY)))")

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
                // Apply raw pixel deltas directly — no coalescing to minimize latency
                if let dx = input.mouseDeltaX, let dy = input.mouseDeltaY {
                    receiverCursorPos.x += CGFloat(dx)
                    receiverCursorPos.y += CGFloat(dy)
                    let b = geometry.bounds
                    receiverCursorPos.x = max(b.minX, min(receiverCursorPos.x, b.maxX))
                    receiverCursorPos.y = max(b.minY, min(receiverCursorPos.y, b.maxY))
                }

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

                CGWarpMouseCursorPosition(receiverCursorPos)
                if let cg = CGEvent(mouseEventSource: nil, mouseType: moveType, mouseCursorPosition: receiverCursorPos, mouseButton: moveButton) {
                    // Set delta fields so apps see smooth relative movement
                    cg.setDoubleValueField(.mouseEventDeltaX, value: Double(input.mouseDeltaX ?? 0))
                    cg.setDoubleValueField(.mouseEventDeltaY, value: Double(input.mouseDeltaY ?? 0))
                    cg.flags = CGEventFlags(rawValue: UInt64(input.flags))
                    cg.setIntegerValueField(.eventSourceUserData, value: Int64(InputShareInjectionMarker.value))
                    cg.post(tap: .cghidEventTap)
                }

                returnEdgeDetector?.update(position: receiverCursorPos)

                // Progressive edge glow — distance to left boundary of cursor's display
                let cursorDisplay = geometry.displayContaining(point: receiverCursorPos)
                let glowZone = cursorDisplay.width * Self.glowZoneFraction
                let dist = geometry.distanceToLeftBoundary(from: receiverCursorPos)
                let prox = max(0, min(1, 1 - dist / glowZone))
                if abs(prox - _receiverProximity) > 0.01 || (prox == 0) != (_receiverProximity == 0) {
                    _receiverProximity = prox
                    DispatchQueue.main.async {
                        self.edgeProximity = prox
                        self.onEdgeGlowUpdate?(prox, false, cursorDisplay.minX)
                    }
                }
            } else if input.kind == .mouseButton {
                // Track button state for drag event generation
                if let button = input.button, let state = input.buttonState {
                    if state == .down {
                        receiverButtonsDown.insert(button)
                    } else {
                        receiverButtonsDown.remove(button)
                    }
                }
                injector?.inject(input)
            } else {
                injector?.inject(input)
            }

        case .deactivate:
            print("[App] Received deactivate — restoring local input")
            isInjecting = false
            receiverTap?.stopSuppressing()
            _receiverProximity = 0
            DispatchQueue.main.async {
                self.edgeProximity = 0
                self.onEdgeGlowUpdate?(0, false, 0)
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
        timer.schedule(deadline: .now(), repeating: Self.coalesceInterval, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if let pending = self.pendingMouseMove {
                self.pendingMouseMove = nil
                self.sendInputEvent(pending)
            }
            if let pending = self.pendingScroll {
                self.pendingScroll = nil
                self.sendInputEvent(pending)
            }
        }
        coalesceTimer = timer
        timer.resume()
    }

    private func stopCoalesceTimer() {
        coalesceTimer?.cancel()
        coalesceTimer = nil
        // Flush any remaining pending events
        if let pending = pendingMouseMove {
            pendingMouseMove = nil
            sendInputEvent(pending)
        }
        if let pending = pendingScroll {
            pendingScroll = nil
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
        // Normalize Y against entire virtual screen bounds (global) so multi-display mirrors correctly
        let geo = senderGeometry ?? ScreenGeometry.allDisplays()
        let normY = (crossingPosition.y - geo.bounds.minY) / geo.bounds.height
        print("[App] Sending activate to receiver (globalNormY=\(String(format: "%.3f", normY)), crossing display=\(Int(crossingDisplayRect.width))x\(Int(crossingDisplayRect.height)))...")
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
        // Normalize return Y against entire virtual screen bounds (global) for multi-display mirroring
        let geo = receiverGeometry ?? ScreenGeometry.allDisplays()
        let normY = (crossingPosition.y - geo.bounds.minY) / geo.bounds.height
        print("[App] Sending deactivate (return) to sender (globalNormY=\(String(format: "%.3f", normY))), restoring local input...")
        receiverTap?.stopSuppressing()
        _receiverProximity = 0
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
            self.edgeProximity = 0
            self.onEdgeGlowUpdate?(0, false, 0)
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
