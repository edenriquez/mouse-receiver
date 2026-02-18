import Foundation
import Network
import Observation

public struct DiscoveredDevice: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    public var endpoint: NWEndpoint

    public init(name: String, endpoint: NWEndpoint) {
        self.name = name
        self.endpoint = endpoint
    }

    public static func == (lhs: DiscoveredDevice, rhs: DiscoveredDevice) -> Bool {
        lhs.name == rhs.name
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
    }
}

@Observable
public final class BonjourBrowser {
    public var devices: [DiscoveredDevice] = []

    private var browser: NWBrowser?
    private let queue: DispatchQueue

    public init(queue: DispatchQueue = .main) {
        self.queue = queue
    }

    public func start() {
        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: "_inputshare._tcp", domain: nil), using: params)

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            let newDevices = results.compactMap { result -> DiscoveredDevice? in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                return DiscoveredDevice(name: name, endpoint: result.endpoint)
            }
            self.devices = newDevices
        }

        browser.start(queue: queue)
        self.browser = browser
    }

    public func stop() {
        browser?.cancel()
        browser = nil
        devices = []
    }
}
