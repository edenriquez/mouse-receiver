import Foundation
import CoreGraphics

public enum EdgeZone: String, Sendable {
    case topRight
    case topLeft
}

public enum EdgeEvent: Sendable {
    case entered
    case triggered
    case exited
}

public struct EdgeTrigger: Sendable {
    public var zone: EdgeZone
    public var enterThreshold: CGFloat
    public var exitThreshold: CGFloat
    public var dwellTime: TimeInterval

    public init(zone: EdgeZone, enterThreshold: CGFloat = 5, exitThreshold: CGFloat = 50, dwellTime: TimeInterval = 0.15) {
        self.zone = zone
        self.enterThreshold = enterThreshold
        self.exitThreshold = exitThreshold
        self.dwellTime = dwellTime
    }
}

public final class EdgeDetector: @unchecked Sendable {
    public var onEdgeEvent: ((EdgeEvent) -> Void)?

    private let trigger: EdgeTrigger
    private let screenWidth: CGFloat
    private let screenHeight: CGFloat
    private var isInZone = false
    private var dwellTimer: DispatchWorkItem?
    private var hasTriggered = false
    private let queue: DispatchQueue

    public init(trigger: EdgeTrigger, screenWidth: CGFloat, screenHeight: CGFloat, queue: DispatchQueue = .main) {
        self.trigger = trigger
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
        self.queue = queue
    }

    public func update(position: CGPoint) {
        let inZone = isInsideEnterZone(position)
        let outsideExit = isOutsideExitZone(position)

        if inZone && !isInZone {
            isInZone = true
            hasTriggered = false
            onEdgeEvent?(.entered)
            startDwellTimer()
        } else if outsideExit && isInZone {
            isInZone = false
            cancelDwellTimer()
            if hasTriggered {
                hasTriggered = false
                onEdgeEvent?(.exited)
            }
        }
    }

    private func isInsideEnterZone(_ pos: CGPoint) -> Bool {
        let t = trigger.enterThreshold
        switch trigger.zone {
        case .topRight:
            return pos.x >= screenWidth - t && pos.y <= t
        case .topLeft:
            return pos.x <= t && pos.y <= t
        }
    }

    private func isOutsideExitZone(_ pos: CGPoint) -> Bool {
        let t = trigger.exitThreshold
        switch trigger.zone {
        case .topRight:
            return pos.x < screenWidth - t || pos.y > t
        case .topLeft:
            return pos.x > t || pos.y > t
        }
    }

    private func startDwellTimer() {
        cancelDwellTimer()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.isInZone else { return }
            self.hasTriggered = true
            self.onEdgeEvent?(.triggered)
        }
        dwellTimer = item
        queue.asyncAfter(deadline: .now() + trigger.dwellTime, execute: item)
    }

    private func cancelDwellTimer() {
        dwellTimer?.cancel()
        dwellTimer = nil
    }
}
