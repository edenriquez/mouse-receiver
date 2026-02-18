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

    let geometry = ScreenGeometry.mainDisplay()
    let returnEdge = EdgeDetector(
        trigger: EdgeTrigger(zone: .topLeft),
        screenWidth: geometry.bounds.width,
        screenHeight: geometry.bounds.height,
        queue: queue
    )

    var activeFramed: NWFramedConnection?
    var isInjecting = false

    returnEdge.onEdgeEvent = { event in
        guard isInjecting, event == .triggered else { return }
        print("[Receiver] Top-left corner detected — sending deactivate")
        isInjecting = false

        let env = MessageEnvelope(
            protocolVersion: InputShareCodec.protocolVersion,
            messageType: .deactivate,
            sequenceNumber: seq.next(),
            monotonicTimeNs: MonotonicClock.nowNs(),
            sourceDeviceId: deviceId,
            payload: Data()
        )
        if let data = try? InputShareCodec.encodeEnvelope(env) {
            activeFramed?.sendFrame(data)
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
                print("[Receiver] Received activate — warping to top-left, now injecting")
                isInjecting = true

                // Place cursor at top-left
                CGWarpMouseCursorPosition(CGPoint(x: 20, y: 20))
                CGAssociateMouseAndMouseCursorPosition(1)
                // Arm return edge — must leave corner before return can trigger
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

let geometry = ScreenGeometry.mainDisplay()
print("[Sender] Screen bounds: \(geometry.bounds)")
let edgeDetector = EdgeDetector(
    trigger: EdgeTrigger(zone: .topRight),
    screenWidth: geometry.bounds.width,
    screenHeight: geometry.bounds.height,
    queue: queue
)
let stateMachine = ForwardingStateMachine(queue: queue)

var capture: EventTapCapture!

stateMachine.onStateChange = { newState in
    print("[Sender] State: \(newState.rawValue)")
    switch newState {
    case .forwarding:
        capture.startSuppressing(virtualStart: CGPoint(x: 20, y: 20))
    case .idle:
        let wasSuppressing = capture.isSuppressing
        capture.stopSuppressing()
        if wasSuppressing {
            let geo = ScreenGeometry.mainDisplay()
            CGWarpMouseCursorPosition(CGPoint(x: geo.bounds.width - 20, y: 20))
            edgeDetector.armAfterEntry()
        }
    default:
        break
    }
}

stateMachine.onShouldSendActivate = {
    print("[Sender] Sending activate...")
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
    if event == .triggered {
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
        print("[Sender] Received deactivate from receiver — returning control")
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
