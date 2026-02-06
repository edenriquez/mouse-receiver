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

    public init(handler: @escaping Handler, queue: DispatchQueue = DispatchQueue(label: "inputshare.capture"), geometry: ScreenGeometry = .mainDisplay()) {
        self.handler = handler
        self.queue = queue
        self.geometry = geometry
    }

    public func start() throws {
        if tap != nil { return }

        let events: [CGEventType] = [
            .mouseMoved,
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
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        runLoopSource = nil
        tap = nil
    }

    private func handle(event: CGEvent, type: CGEventType) {
        let flags = UInt64(event.flags.rawValue)

        switch type {
        case .mouseMoved:
            let loc = event.location
            let n = geometry.normalize(point: loc)
            let e = InputEvent(kind: .mouseMove, normalizedPosition: NormalizedPoint(x: n.x, y: n.y), flags: flags)
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
            let dx = event.getDoubleValueField(.scrollWheelEventDeltaAxis2)
            let dy = event.getDoubleValueField(.scrollWheelEventDeltaAxis1)
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

    private func isSynthetic(event: CGEvent) -> Bool {
        let v = event.getIntegerValueField(.eventSourceUserData)
        return v == InputShareInjectionMarker.value
    }
}
