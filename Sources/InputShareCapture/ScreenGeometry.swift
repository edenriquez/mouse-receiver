import Foundation
import CoreGraphics

public struct ScreenGeometry {
    public var bounds: CGRect

    public init(bounds: CGRect) {
        self.bounds = bounds
    }

    public static func mainDisplay() -> ScreenGeometry {
        let id = CGMainDisplayID()
        let bounds = CGDisplayBounds(id)
        return ScreenGeometry(bounds: bounds)
    }

    public func normalize(point: CGPoint) -> (x: Double, y: Double) {
        let x = (point.x - bounds.minX) / bounds.width
        let y = (point.y - bounds.minY) / bounds.height
        return (x: Double(x), y: Double(y))
    }

    public func denormalize(x: Double, y: Double) -> CGPoint {
        CGPoint(
            x: bounds.minX + CGFloat(x) * bounds.width,
            y: bounds.minY + CGFloat(y) * bounds.height
        )
    }
}
