import CoreGraphics
import Foundation

public enum MouseButton: Sendable {
    case left, right, other
}

public enum CapturedEvent: Sendable {
    case move(dx: Double, dy: Double, location: CGPoint)
    case button(MouseButton, down: Bool)
    case scroll(h: Double, v: Double)
    case key(code: UInt16, down: Bool, flags: UInt64)
}

public enum CaptureError: Error, CustomStringConvertible {
    case tapCreationFailed

    public var description: String {
        "Cannot capture input. Allow DeskBridge in System Settings > Privacy & Security > Accessibility (and Input Monitoring)."
    }
}

/// Active event tap on a dedicated thread. The callback only classifies events and hands them to
/// `onEvent`; it swallows them when `isRemote()` is true. Keep both closures cheap.
public final class InputCapturer: @unchecked Sendable {
    private let isRemote: @Sendable () -> Bool
    private let onEvent: @Sendable (CapturedEvent) -> Void
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?

    public init(isRemote: @escaping @Sendable () -> Bool, onEvent: @escaping @Sendable (CapturedEvent) -> Void) {
        self.isRemote = isRemote
        self.onEvent = onEvent
    }

    public func start() throws {
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            let types: [CGEventType] = [
                .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                .otherMouseDown, .otherMouseUp, .scrollWheel, .keyDown, .keyUp,
            ]
            let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }

            guard let tap = CGEvent.tapCreate(
                tap: .cghidEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: tapCallback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            ) else {
                ready.signal()
                return
            }
            self.tap = tap
            runLoop = CFRunLoopGetCurrent()
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "deskbridge.eventtap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait() // the semaphore orders the writes to `tap` / `runLoop` before this read
        guard tap != nil else { throw CaptureError.tapCreationFailed }
    }

    public func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoop {
            CFRunLoopStop(runLoop)
        }
        tap = nil
        runLoop = nil
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        let remote = isRemote()
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return pass

        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            onEvent(.move(
                dx: event.getDoubleValueField(.mouseEventDeltaX),
                dy: event.getDoubleValueField(.mouseEventDeltaY),
                location: event.location
            ))
            return remote ? nil : pass

        case .leftMouseDown, .leftMouseUp:
            guard remote else { return pass }
            onEvent(.button(.left, down: type == .leftMouseDown))
            return nil

        case .rightMouseDown, .rightMouseUp:
            guard remote else { return pass }
            onEvent(.button(.right, down: type == .rightMouseDown))
            return nil

        case .otherMouseDown, .otherMouseUp:
            guard remote else { return pass }
            onEvent(.button(.other, down: type == .otherMouseDown))
            return nil

        case .scrollWheel:
            guard remote else { return pass }
            onEvent(.scroll(
                h: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2),
                v: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
            ))
            return nil

        case .keyDown, .keyUp:
            guard remote else { return pass }
            onEvent(.key(
                code: UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)),
                down: type == .keyDown,
                flags: event.flags.rawValue
            ))
            return nil

        default:
            return pass
        }
    }
}

private func tapCallback(
    proxy _: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return Unmanaged<InputCapturer>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
}
