import Foundation
import CoreGraphics
import InputShareShared
import InputShareCapture

public final class InputInjector {
    private let geometry: ScreenGeometry

    public init(geometry: ScreenGeometry = .mainDisplay()) {
        self.geometry = geometry
    }

    public func inject(_ event: InputEvent) {
        switch event.kind {
        case .mouseMove:
            if let p = event.normalizedPosition {
                let pt = geometry.denormalize(x: p.x, y: p.y)
                CGWarpMouseCursorPosition(pt)

                if let cg = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: pt, mouseButton: .left) {
                    cg.flags = CGEventFlags(rawValue: UInt64(event.flags))
                    cg.setIntegerValueField(.eventSourceUserData, value: InputShareInjectionMarker.value)
                    cg.post(tap: .cghidEventTap)
                }
            }

        case .mouseButton:
            guard let button = event.button, let state = event.buttonState else { return }
            let loc = CGEvent(source: nil)?.location ?? CGPoint(x: 0, y: 0)
            let type: CGEventType
            let cgButton: CGMouseButton

            switch (button, state) {
            case (.left, .down): type = .leftMouseDown; cgButton = .left
            case (.left, .up): type = .leftMouseUp; cgButton = .left
            case (.right, .down): type = .rightMouseDown; cgButton = .right
            case (.right, .up): type = .rightMouseUp; cgButton = .right
            case (.other, .down): type = .otherMouseDown; cgButton = .center
            case (.other, .up): type = .otherMouseUp; cgButton = .center
            }

            guard let cg = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: loc, mouseButton: cgButton) else { return }
            cg.flags = CGEventFlags(rawValue: UInt64(event.flags))
            cg.setIntegerValueField(.eventSourceUserData, value: InputShareInjectionMarker.value)
            cg.post(tap: .cghidEventTap)

        case .scroll:
            guard let s = event.scroll else { return }
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                   wheel1: Int32(s.deltaY), wheel2: Int32(s.deltaX), wheel3: 0) else { return }
            // Set precise point deltas (the Int32 wheel values lose fractional precision)
            cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: s.deltaY)
            cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: s.deltaX)
            cg.flags = CGEventFlags(rawValue: UInt64(event.flags))
            cg.setIntegerValueField(.eventSourceUserData, value: InputShareInjectionMarker.value)
            cg.post(tap: .cghidEventTap)

        case .key:
            guard let code = event.keyCode, let state = event.keyState else { return }
            let down = state == .down
            guard let cg = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { return }
            cg.flags = CGEventFlags(rawValue: UInt64(event.flags))
            cg.setIntegerValueField(.eventSourceUserData, value: InputShareInjectionMarker.value)
            cg.post(tap: .cghidEventTap)

        case .flagsChanged:
            break
        }
    }
}
