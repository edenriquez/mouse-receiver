import Foundation
import Network
import Security
import CryptoKit

public struct TLSConfig {
    public var identityP12Path: String
    public var identityP12Password: String
    public var pinnedPeerCertificateSHA256Hex: String?

    public init(identityP12Path: String, identityP12Password: String, pinnedPeerCertificateSHA256Hex: String?) {
        self.identityP12Path = identityP12Path
        self.identityP12Password = identityP12Password
        self.pinnedPeerCertificateSHA256Hex = pinnedPeerCertificateSHA256Hex
    }
}

public enum NWTransport {
    public static func makeClientConnection(host: String, port: UInt16, tls: TLSConfig) throws -> NWConnection {
        let params = NWParameters.tcp
        params.defaultProtocolStack.applicationProtocols.insert(makeTLSOptions(tls: tls), at: 0)
        return NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: params)
    }

    public static func makeListener(port: UInt16, tls: TLSConfig) throws -> NWListener {
        let params = NWParameters.tcp
        params.defaultProtocolStack.applicationProtocols.insert(makeTLSOptions(tls: tls), at: 0)
        return try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
    }

    private static func makeTLSOptions(tls: TLSConfig) -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        let secOptions = options.securityProtocolOptions

        sec_protocol_options_set_peer_authentication_required(secOptions, true)

        if let identity = loadIdentity(p12Path: tls.identityP12Path, password: tls.identityP12Password) {
            sec_protocol_options_set_local_identity(secOptions, identity)
        }

        if let pinnedHex = tls.pinnedPeerCertificateSHA256Hex {
            sec_protocol_options_set_verify_block(secOptions, { _, secTrust, complete in
                let trust = sec_trust_copy_ref(secTrust).takeRetainedValue()
                let ok = verifyPinnedCertificate(trust: trust, pinnedHex: pinnedHex)
                complete(ok)
            }, DispatchQueue.global(qos: .userInitiated))
        } else {
            sec_protocol_options_set_verify_block(secOptions, { _, _, complete in
                complete(false)
            }, DispatchQueue.global(qos: .userInitiated))
        }

        return options
    }

    private static func loadIdentity(p12Path: String, password: String) -> sec_identity_t? {
        let url = URL(fileURLWithPath: p12Path)
        guard let p12Data = try? Data(contentsOf: url) else { return nil }

        let options: [String: Any] = [kSecImportExportPassphrase as String: password]
        var items: CFArray?
        let status = SecPKCS12Import(p12Data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess, let array = items as? [[String: Any]], let first = array.first else { return nil }
        guard let identity = first[kSecImportItemIdentity as String] else { return nil }
        return sec_identity_create(identity as! SecIdentity)
    }

    private static func verifyPinnedCertificate(trust: SecTrust, pinnedHex: String) -> Bool {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let cert = chain.first else { return false }
        let data = SecCertificateCopyData(cert) as Data
        let digest = SHA256.hash(data: data)
        let hex = digest.compactMap { String(format: "%02x", $0) }.joined()
        return hex == pinnedHex.lowercased()
    }
}
