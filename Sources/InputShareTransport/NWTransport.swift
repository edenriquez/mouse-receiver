import Foundation
import Network

public enum NWTransport {
    public static func makeClientConnection(host: String, port: UInt16) -> NWConnection {
        let params = NWParameters.tcp
        return NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: params)
    }

    public static func makeListener(port: UInt16) throws -> NWListener {
        let params = NWParameters.tcp
        return try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
    }
}
