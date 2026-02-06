import Foundation
import ApplicationServices
import Network
import InputShareShared
import InputShareTransport
import InputShareCapture
import InputShareInjection

struct Args {
    var mode: String
    var host: String?
    var port: UInt16
    var identityP12Path: String
    var identityP12Password: String
    var pinnedPeerCertSHA256: String
}

func parseArgs() -> Args? {
    var mode: String?
    var host: String?
    var port: UInt16?
    var p12: String?
    var p12Pass: String?
    var pin: String?

    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = it.next() {
        switch arg {
        case "send", "receive":
            mode = arg
        case "--host":
            host = it.next()
        case "--port":
            if let s = it.next(), let p = UInt16(s) { port = p }
        case "--identity-p12":
            p12 = it.next()
        case "--identity-pass":
            p12Pass = it.next()
        case "--pin-sha256":
            pin = it.next()
        default:
            break
        }
    }

    guard let m = mode else { return nil }
    guard let p = port else { return nil }
    guard let p12, let p12Pass, let pin else { return nil }
    if m == "send" && host == nil { return nil }

    return Args(mode: m, host: host, port: p, identityP12Path: p12, identityP12Password: p12Pass, pinnedPeerCertSHA256: pin)
}

func ensureAccessibilityPrompt() {
    let opts = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(opts)
}

func usage() {
    let exe = (CommandLine.arguments.first ?? "inputshare")
    print("Usage:\n  \(exe) send --host <ip> --port <port> --identity-p12 <path> --identity-pass <pass> --pin-sha256 <hex>\n  \(exe) receive --port <port> --identity-p12 <path> --identity-pass <pass> --pin-sha256 <hex>")
}

guard let args = parseArgs() else {
    usage()
    exit(2)
}

ensureAccessibilityPrompt()

let tls = TLSConfig(identityP12Path: args.identityP12Path, identityP12Password: args.identityP12Password, pinnedPeerCertificateSHA256Hex: args.pinnedPeerCertSHA256)
let deviceId = Host.current().localizedName ?? UUID().uuidString

final class Sequencer {
    private var n: UInt64 = 0
    func next() -> UInt64 { n += 1; return n }
}

let seq = Sequencer()
let queue = DispatchQueue(label: "inputshare.main")

if args.mode == "receive" {
    let injector = InputInjector()
    let listener = try NWTransport.makeListener(port: args.port, tls: tls)

    listener.newConnectionHandler = { conn in
        let framed = NWFramedConnection(connection: conn, queue: queue)
        framed.onFrame = { data in
            guard let env = try? InputShareCodec.decodeEnvelope(data) else { return }
            if env.messageType == .inputEvent {
                guard let input = try? InputShareCodec.decodePayload(InputEvent.self, from: env.payload) else { return }
                injector.inject(input)
            }
        }
        framed.start()
    }

    listener.start(queue: queue)
    dispatchMain()
} else {
    let conn = try NWTransport.makeClientConnection(host: args.host!, port: args.port, tls: tls)
    let framed = NWFramedConnection(connection: conn, queue: queue)

    framed.start()

    let capture = EventTapCapture(handler: { input in
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
    })

    try capture.start()
    dispatchMain()
}
