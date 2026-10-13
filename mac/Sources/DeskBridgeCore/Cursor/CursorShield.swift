import AppKit

/// Makes the frozen Mac cursor invisible while Android has control.
///
/// `CGDisplayHideCursor` from a background app is unreliable: macOS keeps the Dock in cursor control, and
/// other apps' floating panels win too. What does work is being the foreground app with a window above
/// everything (above the Dock level) and setting a transparent cursor image over it. So this puts a
/// near-invisible borderless window on the display, activates the app, and restores the previously active
/// app on `hide()`. Safe to call from any thread.
final class CursorShield: @unchecked Sendable {
    private var window: NSWindow? // touched on the main thread only
    private var previousApp: NSRunningApplication?

    /// `bounds` is in global CoreGraphics coordinates (origin at the top-left of the primary display).
    /// `completion` runs on the main thread once the window is up and the app is active.
    func show(covering bounds: CGRect, then completion: @escaping @Sendable () -> Void) {
        DispatchQueue.main.async {
            let me = NSRunningApplication.current
            if let front = NSWorkspace.shared.frontmostApplication, front != me {
                self.previousApp = front
            }

            let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
            let frame = NSRect(
                x: bounds.minX,
                y: primaryHeight - bounds.maxY,
                width: bounds.width,
                height: bounds.height
            )
            let window = ShieldWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.level = .screenSaver // well above the Dock window level
            window.isOpaque = false
            // 5%, not 1%: nearly transparent windows are treated differently by the window server, and
            // Apple's guidance for this problem is 5-10%.
            window.backgroundColor = NSColor.black.withAlphaComponent(0.05)
            window.hasShadow = false
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            window.contentView = BlankCursorView(frame: NSRect(origin: .zero, size: frame.size))
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            window.invalidateCursorRects(for: window.contentView!)
            self.window = window

            // Give the window server a moment to hand the cursor to us before the caller warps it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: completion)
        }
    }

    func hide() {
        DispatchQueue.main.async {
            self.window?.orderOut(nil)
            self.window = nil
            // Keep `previousApp`: a quick re-entry may happen before the system has switched back, and then
            // the front app is still us; `show()` only overwrites it when another app is in front.
            if let previous = self.previousApp, !previous.isTerminated {
                previous.activate()
            }
        }
    }
}

private final class ShieldWindow: NSWindow {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }
}

/// A view whose whole area shows a fully transparent cursor.
private final class BlankCursorView: NSView {
    private static let blank: NSCursor = {
        let image = NSImage(size: NSSize(width: 16, height: 16))
        return NSCursor(image: image, hotSpot: .zero)
    }()

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: Self.blank)
    }
}
