import Foundation
import Network

public final class BonjourAdvertiser {
    private var listener: NWListener?
    private let port: UInt16
    private let queue: DispatchQueue

    public var onReady: (() -> Void)?
    public var onNewConnection: ((NWConnection) -> Void)?

    public init(port: UInt16 = 4242, queue: DispatchQueue = .main) {
        self.port = port
        self.queue = queue
    }

    public func start() throws {
        let params = NWParameters.tcp
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener.service = NWListener.Service(name: nil, type: "_inputshare._tcp")

        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.onReady?()
            }
        }

        listener.newConnectionHandler = { [weak self] conn in
            self?.onNewConnection?(conn)
        }

        listener.start(queue: queue)
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }
}
