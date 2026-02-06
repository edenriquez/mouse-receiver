import Foundation
import Network

public final class NWFramedConnection {
    private let connection: NWConnection
    private var receiveBuffer = Data()
    private let queue: DispatchQueue

    public var onFrame: ((Data) -> Void)?
    public var onState: ((NWConnection.State) -> Void)?

    public init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            self?.onState?(state)
        }
        connection.start(queue: queue)
        receiveLoop()
    }

    public func cancel() {
        connection.cancel()
    }

    public func sendFrame(_ payload: Data, completion: ((NWError?) -> Void)? = nil) {
        let framed = Framing.frame(payload)
        connection.send(content: framed, completion: .contentProcessed { err in
            completion?(err)
        })
    }

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] content, _, isComplete, error in
            guard let self else { return }

            if let content, !content.isEmpty {
                self.receiveBuffer.append(content)
                let frames = Framing.deframe(buffer: &self.receiveBuffer)
                for f in frames {
                    self.onFrame?(f)
                }
            }

            if error != nil || isComplete {
                return
            }

            self.receiveLoop()
        }
    }
}
