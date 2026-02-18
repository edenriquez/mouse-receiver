import Foundation
import ApplicationServices
import Network
import InputShareShared
import InputShareTransport
import InputShareCapture
import InputShareInjection
import InputShareEdge

struct Args {
    var mode: String
    var host: String?
    var port: UInt16
}

func parseArgs() -> Args? {
    var mode: String?
    var host: String?
    var port: UInt16?

    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = it.next() {
        switch arg {
        case "send", "receive", "mock-receive":
            mode = arg
        case "--host":
            host = it.next()
        case "--port":
            if let s = it.next(), let p = UInt16(s) { port = p }
        default:
            break
        }
    }

    guard let m = mode else { return nil }
    guard let p = port else { return nil }
    if m == "send" && host == nil { return nil }

    return Args(mode: m, host: host, port: p)
}

func ensureAccessibilityPrompt() {
    let opts = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(opts)
}

func usage() {
    let exe = (CommandLine.arguments.first ?? "inputshare")
    print("""
    Usage:
      \(exe) send --host <ip> --port <port>
      \(exe) receive --port <port>
      \(exe) mock-receive --port <port>
    """)
}

guard let args = parseArgs() else {
    usage()
    exit(2)
}

let deviceId = Host.current().localizedName ?? UUID().uuidString

final class Sequencer {
    private var n: UInt64 = 0
    func next() -> UInt64 { n += 1; return n }
}

let seq = Sequencer()
let queue = DispatchQueue(label: "inputshare.main")

// MARK: - Mock Receive Mode

if args.mode == "mock-receive" {
    print("[MockReceiver] Starting on port \(args.port)...")
    let listener = try NWTransport.makeListener(port: args.port)

    listener.newConnectionHandler = { conn in
        print("[MockReceiver] New connection from \(conn.endpoint)")
        let framed = NWFramedConnection(connection: conn, queue: queue)

        framed.onState = { state in
            print("[MockReceiver] Connection state: \(state)")
        }

        framed.onFrame = { data in
            guard let env = try? InputShareCodec.decodeEnvelope(data) else { return }

            switch env.messageType {
            case .activate:
                print("[MockReceiver] Received activate — sending activated ack")
                let ackPayload = Data()
                let ack = MessageEnvelope(
                    protocolVersion: InputShareCodec.protocolVersion,
                    messageType: .activated,
                    sequenceNumber: 0,
                    monotonicTimeNs: MonotonicClock.nowNs(),
                    sourceDeviceId: "mock-receiver",
                    payload: ackPayload
                )
                if let ackData = try? InputShareCodec.encodeEnvelope(ack) {
                    framed.sendFrame(ackData)
                }

            case .inputEvent:
                if let input = try? InputShareCodec.decodePayload(InputEvent.self, from: env.payload) {
                    let json = try? JSONEncoder().encode(input)
                    let jsonStr = json.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                    print(jsonStr)
                }

            case .deactivate:
                print("[MockReceiver] Received deactivate")
                let ack = MessageEnvelope(
                    protocolVersion: InputShareCodec.protocolVersion,
                    messageType: .deactivated,
                    sequenceNumber: 0,
                    monotonicTimeNs: MonotonicClock.nowNs(),
                    sourceDeviceId: "mock-receiver",
                    payload: Data()
                )
                if let ackData = try? InputShareCodec.encodeEnvelope(ack) {
                    framed.sendFrame(ackData)
                }

            default:
                print("[MockReceiver] Received: \(env.messageType.rawValue)")
            }
        }
        framed.start()
    }

    listener.stateUpdateHandler = { state in
        print("[MockReceiver] Listener state: \(state)")
    }
    listener.start(queue: queue)
    dispatchMain()
}

// MARK: - Receive Mode

if args.mode == "receive" {
    ensureAccessibilityPrompt()
    let injector = InputInjector()
    let listener = try NWTransport.makeListener(port: args.port)

    let geometry = ScreenGeometry.allDisplays()
    let returnEdge = EdgeDetector(
        trigger: EdgeTrigger(zone: .left, dwellTime: 0.1),
        screenBounds: geometry.bounds,
        queue: queue
    )

    var activeFramed: NWFramedConnection?
    var isInjecting = false

    returnEdge.onEdgeEvent = { event in
        guard isInjecting else { return }
        if case .triggered(let pos) = event {
            print("[Receiver] Left edge triggered at Y=\(Int(pos.y)) — sending deactivate")
            isInjecting = false
            let normY = geometry.normalize(point: pos).y
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
                activeFramed?.sendFrame(data)
            }
        }
    }

    listener.newConnectionHandler = { conn in
        print("[Receiver] New connection from \(conn.endpoint)")
        let framed = NWFramedConnection(connection: conn, queue: queue)
        activeFramed = framed

        framed.onState = { state in
            print("[Receiver] Connection state: \(state)")
        }

        framed.onFrame = { data in
            guard let env = try? InputShareCodec.decodeEnvelope(data) else { return }

            switch env.messageType {
            case .activate:
                isInjecting = true
                let activatePayload = try? InputShareCodec.decodePayload(ActivatePayload.self, from: env.payload)
                let normY = activatePayload?.normalizedPosition.y ?? 0.5
                let cursorY = geometry.denormalize(x: 0, y: normY).y
                print("[Receiver] Received activate — placing cursor at left edge Y=\(Int(cursorY))")

                CGWarpMouseCursorPosition(CGPoint(x: geometry.bounds.minX + 2, y: cursorY))
                CGAssociateMouseAndMouseCursorPosition(1)
                returnEdge.armAfterEntry()

                let ack = MessageEnvelope(
                    protocolVersion: InputShareCodec.protocolVersion,
                    messageType: .activated,
                    sequenceNumber: seq.next(),
                    monotonicTimeNs: MonotonicClock.nowNs(),
                    sourceDeviceId: deviceId,
                    payload: Data()
                )
                if let ackData = try? InputShareCodec.encodeEnvelope(ack) {
                    framed.sendFrame(ackData)
                }

            case .inputEvent:
                guard isInjecting else { return }
                guard let input = try? InputShareCodec.decodePayload(InputEvent.self, from: env.payload) else { return }
                injector.inject(input)

                // Feed mouse moves to return edge detector
                if input.kind == .mouseMove, let pos = input.normalizedPosition {
                    let pt = geometry.denormalize(x: pos.x, y: pos.y)
                    returnEdge.update(position: pt)
                }

            case .deactivated:
                print("[Receiver] Received deactivated ack")
                isInjecting = false

            default:
                break
            }
        }
        framed.start()
    }

    listener.stateUpdateHandler = { state in
        print("[Receiver] Listener state: \(state)")
    }
    listener.start(queue: queue)
    print("[Receiver] Listening on port \(args.port)...")
    dispatchMain()
}

// MARK: - Send Mode

ensureAccessibilityPrompt()

let conn = NWTransport.makeClientConnection(host: args.host!, port: args.port)
let framed = NWFramedConnection(connection: conn, queue: queue)

let geometry = ScreenGeometry.allDisplays()
print("[Sender] Screen bounds: \(geometry.bounds)")
let edgeDetector = EdgeDetector(
    trigger: EdgeTrigger(zone: .right, dwellTime: 0.1),
    screenBounds: geometry.bounds,
    queue: queue
)
let stateMachine = ForwardingStateMachine(queue: queue)

var capture: EventTapCapture!
var crossingPosition: CGPoint = .zero

stateMachine.onStateChange = { newState in
    print("[Sender] State: \(newState.rawValue)")
    switch newState {
    case .forwarding:
        let geo = ScreenGeometry.allDisplays()
        capture.startSuppressing(virtualStart: CGPoint(x: geo.bounds.minX, y: crossingPosition.y))
    case .idle:
        let wasSuppressing = capture.isSuppressing
        capture.stopSuppressing()
        if wasSuppressing {
            let geo = ScreenGeometry.allDisplays()
            CGWarpMouseCursorPosition(CGPoint(x: geo.bounds.maxX - 2, y: crossingPosition.y))
            edgeDetector.armAfterEntry()
        }
    default:
        break
    }
}

stateMachine.onShouldSendActivate = {
    let normY = geometry.normalize(point: crossingPosition).y
    print("[Sender] Sending activate (normY=\(String(format: "%.3f", normY)))...")
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
        framed.sendFrame(data)
    }
}

stateMachine.onShouldSendDeactivate = {
    print("[Sender] Sending deactivate...")
    let env = MessageEnvelope(
        protocolVersion: InputShareCodec.protocolVersion,
        messageType: .deactivate,
        sequenceNumber: seq.next(),
        monotonicTimeNs: MonotonicClock.nowNs(),
        sourceDeviceId: deviceId,
        payload: Data()
    )
    if let data = try? InputShareCodec.encodeEnvelope(env) {
        framed.sendFrame(data)
    }
}

edgeDetector.onEdgeEvent = { event in
    if case .triggered(let pos) = event {
        print("[Sender] Right edge triggered at Y=\(Int(pos.y))")
        crossingPosition = pos
        stateMachine.edgeTriggered()
    }
}

framed.onState = { state in
    print("[Sender] Connection state: \(state)")
}

framed.onFrame = { data in
    guard let env = try? InputShareCodec.decodeEnvelope(data) else { return }
    switch env.messageType {
    case .activated:
        print("[Sender] Received activated ack")
        stateMachine.receivedActivated()
    case .deactivate:
        if let deactPayload = try? InputShareCodec.decodePayload(DeactivatePayload.self, from: env.payload) {
            let returnY = geometry.denormalize(x: 0, y: deactPayload.normalizedY).y
            crossingPosition = CGPoint(x: geometry.bounds.maxX, y: returnY)
            print("[Sender] Received deactivate from receiver — returning at Y=\(Int(returnY))")
        } else {
            print("[Sender] Received deactivate from receiver — returning control")
        }
        stateMachine.receivedDeactivate()
    case .deactivated:
        stateMachine.receivedDeactivated()
    default:
        break
    }
}

framed.start()
print("[Sender] Connecting to \(args.host!):\(args.port)...")

capture = EventTapCapture(handler: { input in
    guard stateMachine.state == .forwarding else { return }
    let payload = (try? InputShareCodec.encodePayload(input)) ?? Data()
    let env = MessageEnvelope(
        protocolVersion: InputShareCodec.protocolVersion,
        messageType: .inputEvent,
        sequenceNumber: seq.next(),
        monotonicTimeNs: MonotonicClock.nowNs(),
        sourceDeviceId: deviceId,
        payload: payload
    )
    guard let data = try? InputShareCodec.encodeEnvelope(env) else { return }
    framed.sendFrame(data)
}, geometry: geometry)

capture.onRawMouseMove = { point in
    edgeDetector.update(position: point)
}

try capture.start()
dispatchMain()
