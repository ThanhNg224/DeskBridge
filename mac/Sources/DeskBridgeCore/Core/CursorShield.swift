import AppKit

/// A near-invisible window above everything on one display. While Android has control the frozen Mac
/// cursor sits under it, so this app (not a floating panel of another app, e.g. ChatGPT) owns the cursor
/// image and our hide request is honored. Safe to call from any thread.
final class CursorShield: @unchecked Sendable {
    private var window: NSWindow? // touched on the main thread only

    /// `bounds` is in global CoreGraphics coordinates (origin at the top-left of the primary display).
    func show(covering bounds: CGRect, then completion: @escaping @Sendable () -> Void) {
        DispatchQueue.main.async {
            let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
            let frame = NSRect(
                x: bounds.minX,
                y: primaryHeight - bounds.maxY,
                width: bounds.width,
                height: bounds.height
            )
            let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.level = .screenSaver
            window.isOpaque = false
            // Not fully transparent: WindowServer lets mouse events (and cursor ownership) pass through alpha 0.
            window.backgroundColor = NSColor.black.withAlphaComponent(0.01)
            window.hasShadow = false
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            window.orderFrontRegardless()
            self.window = window
            completion()
        }
    }

    func hide() {
        DispatchQueue.main.async {
            self.window?.orderOut(nil)
            self.window = nil
        }
    }
}
