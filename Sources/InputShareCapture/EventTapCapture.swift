import Foundation
import CoreGraphics
import InputShareShared

public final class EventTapCapture {
    public typealias Handler = @Sendable (InputEvent) -> Void

    private let handler: Handler
    private let queue: DispatchQueue
    private let geometry: ScreenGeometry
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// True when local HID events are swallowed by the event tap.
    public private(set) var isSuppressing: Bool = false

    /// Fires raw screen position on every mouse move before normalization.
    /// When suppressing, this fires the virtual cursor position.
    public var onRawMouseMove: ((CGPoint) -> Void)?

    /// Virtual cursor position tracked via deltas when suppressing
    private var virtualPosition: CGPoint = .zero
    private var cursorHidden: Bool = false
    /// Center of screen — cursor gets warped here on every local event to keep it pinned
    private var pinPoint: CGPoint = .zero
    /// Number of mouse-move events to drop after entering suppression,
    /// to discard the warp-to-pinPoint delta that CGWarpMouseCursorPosition generates.
    private var suppressionWarmup: Int = 0

    /// Begin suppressing: freeze cursor from HID, optionally hide it,
    /// track a virtual cursor from `virtualStart` for position events.
    /// - Parameters:
    ///   - virtualStart: Starting point of the virtual cursor in screen coordinates.
    ///   - hideCursor: If true (sender), hides the cursor. If false (receiver), cursor stays visible.
    public func startSuppressing(virtualStart: CGPoint, hideCursor: Bool = true) {
        guard !isSuppressing else { return }
        virtualPosition = virtualStart
        pinPoint = CGPoint(x: geometry.bounds.midX, y: geometry.bounds.midY)
        // Drop the first few mouse-move events after suppression starts.
        // CGWarpMouseCursorPosition(pinPoint) generates a CGEvent whose delta
        // equals the warp distance (edge→center), which would be forwarded
        // as real mouse movement otherwise.
        suppressionWarmup = hideCursor ? 3 : 0
        isSuppressing = true
        CGAssociateMouseAndMouseCursorPosition(0)
        if hideCursor {
            // Sender: pin cursor to center and hide it
            CGWarpMouseCursorPosition(pinPoint)
            CGDisplayHideCursor(CGMainDisplayID())
            cursorHidden = true
        }
        // Receiver: cursor stays visible at current position, controlled by injector
    }

    /// Stop suppressing: restore HID association and show cursor if it was hidden.
    public func stopSuppressing() {
        guard isSuppressing else { return }
        isSuppressing = false
        if cursorHidden {
            CGDisplayShowCursor(CGMainDisplayID())
            cursorHidden = false
        }
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    public init(handler: @escaping Handler, queue: DispatchQueue = DispatchQueue(label: "inputshare.capture"), geometry: ScreenGeometry = .mainDisplay()) {
        self.handler = handler
        self.queue = queue
        self.geometry = geometry
    }

    public func start() throws {
        if tap != nil { return }

        let events: [CGEventType] = [
            .mouseMoved,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged,
            .leftMouseDown,
            .leftMouseUp,
            .rightMouseDown,
            .rightMouseUp,
            .otherMouseDown,
            .otherMouseUp,
            .scrollWheel,
            .keyDown,
            .keyUp,
            .flagsChanged
        ]

        let mask = events.reduce(CGEventMask(0)) { partial, type in
            partial | (CGEventMask(1) << CGEventMask(type.rawValue))
        }

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            let unmanagedSelf = Unmanaged<EventTapCapture>.fromOpaque(userInfo!).takeUnretainedValue()

            if unmanagedSelf.isSynthetic(event: event) {
                return Unmanaged.passUnretained(event)
            }

            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = unmanagedSelf.tap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }

            if unmanagedSelf.isSuppressing {
                // During warmup, drop mouse-move events to discard warp-generated deltas
                if EventTapCapture.isMouseMoveType(type) && unmanagedSelf.suppressionWarmup > 0 {
                    unmanagedSelf.suppressionWarmup -= 1
                    if unmanagedSelf.cursorHidden {
                        CGWarpMouseCursorPosition(unmanagedSelf.pinPoint)
                    }
                    return nil
                }

                // Track virtual cursor via deltas while real cursor is pinned
                if EventTapCapture.isMouseMoveType(type) {
                    let dx = CGFloat(event.getDoubleValueField(.mouseEventDeltaX))
                    let dy = CGFloat(event.getDoubleValueField(.mouseEventDeltaY))
                    unmanagedSelf.virtualPosition.x += dx
                    unmanagedSelf.virtualPosition.y += dy
                    let b = unmanagedSelf.geometry.bounds
                    unmanagedSelf.virtualPosition.x = max(b.minX, min(unmanagedSelf.virtualPosition.x, b.maxX))
                    unmanagedSelf.virtualPosition.y = max(b.minY, min(unmanagedSelf.virtualPosition.y, b.maxY))
                    unmanagedSelf.onRawMouseMove?(unmanagedSelf.virtualPosition)
                }

                unmanagedSelf.handle(event: event, type: type)

                // Only warp cursor to center on sender (cursor hidden).
                // On receiver the cursor is visible and controlled by the injector —
                // warping here would fight with injected positions.
                if unmanagedSelf.cursorHidden {
                    CGWarpMouseCursorPosition(unmanagedSelf.pinPoint)
                }

                // Swallow the event so apps don't see it
                return nil
            }

            // Normal (not suppressing) path
            if EventTapCapture.isMouseMoveType(type) {
                unmanagedSelf.onRawMouseMove?(event.location)
            }

            unmanagedSelf.handle(event: event, type: type)
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            throw NSError(domain: "InputShareCapture", code: 1)
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    public func stop() {
        if isSuppressing {
            stopSuppressing()
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        runLoopSource = nil
        tap = nil
    }

    private func handle(event: CGEvent, type: CGEventType) {
        let flags = UInt64(event.flags.rawValue)

        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            let loc: CGPoint
            if isSuppressing {
                loc = virtualPosition
            } else {
                loc = event.location
            }
            let n = geometry.normalize(point: loc)
            let dx = event.getDoubleValueField(.mouseEventDeltaX)
            let dy = event.getDoubleValueField(.mouseEventDeltaY)
            let e = InputEvent(kind: .mouseMove, normalizedPosition: NormalizedPoint(x: n.x, y: n.y), mouseDeltaX: dx, mouseDeltaY: dy, flags: flags)
            queue.async { self.handler(e) }

        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
            let button: MouseButton
            if type == .leftMouseDown || type == .leftMouseUp {
                button = .left
            } else if type == .rightMouseDown || type == .rightMouseUp {
                button = .right
            } else {
                button = .other
            }
            let state: ButtonState = (type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown) ? .down : .up
            let e = InputEvent(kind: .mouseButton, button: button, buttonState: state, flags: flags)
            queue.async { self.handler(e) }

        case .scrollWheel:
            // Use pixel deltas (not line deltas) to match .pixel injection units
            let dx = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
            let dy = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
            let e = InputEvent(kind: .scroll, scroll: ScrollDelta(deltaX: dx, deltaY: dy), flags: flags)
            queue.async { self.handler(e) }

        case .keyDown, .keyUp:
            let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let state: ButtonState = (type == .keyDown) ? .down : .up
            let e = InputEvent(kind: .key, keyCode: code, keyState: state, flags: flags)
            queue.async { self.handler(e) }

        case .flagsChanged:
            let e = InputEvent(kind: .flagsChanged, flags: flags)
            queue.async { self.handler(e) }

        default:
            break
        }
    }

    private static func isMouseMoveType(_ type: CGEventType) -> Bool {
        type == .mouseMoved || type == .leftMouseDragged || type == .rightMouseDragged || type == .otherMouseDragged
    }

    private func isSynthetic(event: CGEvent) -> Bool {
        let v = event.getIntegerValueField(.eventSourceUserData)
        return v == InputShareInjectionMarker.value
    }
}
