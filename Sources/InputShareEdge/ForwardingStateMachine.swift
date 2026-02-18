import Foundation

public enum ForwardingState: String, Sendable {
    case idle
    case candidate
    case activating
    case forwarding
    case returning
}

public final class ForwardingStateMachine: @unchecked Sendable {
    public private(set) var state: ForwardingState = .idle

    public var onStateChange: ((ForwardingState) -> Void)?
    public var onShouldSendActivate: (() -> Void)?
    public var onShouldSendDeactivate: (() -> Void)?

    private var activationTimeout: DispatchWorkItem?
    private let queue: DispatchQueue
    private let timeoutDuration: TimeInterval

    public init(queue: DispatchQueue = .main, timeoutDuration: TimeInterval = 2.0) {
        self.queue = queue
        self.timeoutDuration = timeoutDuration
    }

    // Edge triggered (dwell complete on sender's top-right)
    public func edgeTriggered() {
        guard state == .idle else { return }
        transition(to: .candidate)
        transition(to: .activating)
        onShouldSendActivate?()
        startActivationTimeout()
    }

    // Received `activated` ack from receiver
    public func receivedActivated() {
        guard state == .activating else { return }
        cancelTimeout()
        transition(to: .forwarding)
    }

    // Edge triggered on receiver side (top-left) — return control
    public func returnTriggered() {
        guard state == .forwarding else { return }
        transition(to: .returning)
        onShouldSendDeactivate?()
        transition(to: .idle)
    }

    // Received `deactivate` from sender telling us to stop
    public func receivedDeactivate() {
        guard state == .forwarding else { return }
        transition(to: .idle)
    }

    // Received `deactivated` ack from receiver
    public func receivedDeactivated() {
        if state == .returning {
            transition(to: .idle)
        }
    }

    // Cancel forwarding (e.g., connection lost)
    public func reset() {
        cancelTimeout()
        transition(to: .idle)
    }

    private func transition(to newState: ForwardingState) {
        guard state != newState else { return }
        state = newState
        onStateChange?(newState)
    }

    private func startActivationTimeout() {
        cancelTimeout()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.state == .activating else { return }
            self.transition(to: .idle)
        }
        activationTimeout = item
        queue.asyncAfter(deadline: .now() + timeoutDuration, execute: item)
    }

    private func cancelTimeout() {
        activationTimeout?.cancel()
        activationTimeout = nil
    }
}
