import AppKit
import Carbon.HIToolbox

/// Makes the frozen Mac cursor invisible while Android has control.
///
/// `CGDisplayHideCursor` from a background app is unreliable: macOS keeps the Dock in cursor control, and
/// other apps' floating panels win too. What does work is being the foreground app with a window above
/// everything (above the Dock level) and setting a transparent cursor image over it. So this puts a
/// near-invisible borderless window on the display, activates the app, and restores the previously active
/// app on `hide()`. Safe to call from any thread.
final class CursorShield: @unchecked Sendable {
    private let keyboard: KeyboardStateBox
    private var window: NSWindow? // touched on the main thread only
    private var composer: ComposerView?
    private var preview: NSTextField? // shows the word an input method is composing
    private var observers: [NSObjectProtocol] = []
    private var previousApp: NSRunningApplication?
    private var textHandler: (@Sendable (String) -> Void)?
    private var commandHandler: (@Sendable (UInt16, UInt64) -> Void)?

    init(keyboard: KeyboardStateBox) {
        self.keyboard = keyboard
    }

    /// Where the Mac input method's output goes: committed text, and keys it hands back unhandled (code, flags).
    /// Called on the main thread.
    func setKeyboardHandlers(
        text: @escaping @Sendable (String) -> Void,
        command: @escaping @Sendable (UInt16, UInt64) -> Void
    ) {
        DispatchQueue.main.async {
            self.textHandler = text
            self.commandHandler = command
        }
    }

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
            self.window = window
            self.setUpKeyboard(in: window)
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            window.invalidateCursorRects(for: window.contentView!)
            self.focusComposer()

            // Give the window server a moment to hand the cursor to us before the caller warps it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: completion)
        }
    }

    /// True when the system cursor is our transparent one (the shield's cursor rect took effect).
    func cursorIsBlank(_ result: @escaping @Sendable (Bool) -> Void) {
        DispatchQueue.main.async {
            result(NSCursor.currentSystem?.image.size == BlankCursorView.blankSize)
        }
    }

    /// Asks again for the transparent cursor: re-applies the cursor rects, and with `reactivate` also takes key/active
    /// status again.
    func refreshCursor(reactivate: Bool) {
        DispatchQueue.main.async {
            guard let window = self.window, let view = window.contentView else { return }
            window.invalidateCursorRects(for: view)
            BlankCursorView.blank.set()
            if reactivate {
                window.makeKeyAndOrderFront(nil)
                NSApplication.shared.activate(ignoringOtherApps: true)
                self.focusComposer()
            }
        }
    }

    /// Commit a marked word before a shortcut can change the focused Android app.
    func commitComposition(then completion: @escaping @Sendable () -> Void) {
        DispatchQueue.main.async {
            if let composer = self.composer, composer.hasMarkedText() {
                composer.unmarkText()
                composer.inputContext?.discardMarkedText()
            }
            completion()
        }
    }

    func hide() {
        DispatchQueue.main.async {
            self.tearDownKeyboard()
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

// MARK: - Keyboard (Mac input methods)

@MainActor private extension CursorShield {
    /// With a composing input method selected, text keys are let through to an invisible text input view in the shield
    /// window (see `KeyRouting`); this wires that view and tells the event tap when it can take keys.
    func setUpKeyboard(in window: NSWindow) {
        keyboard.update {
            $0 = KeyboardState(imeActive: InputSource.composesText(), ready: false, composing: false)
        }
        guard let content = window.contentView else { return }

        let preview = NSTextField(labelWithString: "")
        preview.font = .systemFont(ofSize: 24)
        preview.textColor = .white
        preview.drawsBackground = true
        preview.backgroundColor = NSColor.black.withAlphaComponent(0.75)
        preview.isHidden = true
        content.addSubview(preview)
        self.preview = preview

        let composer = ComposerView(keyboard: keyboard)
        composer.onText = textHandler
        composer.onCommand = commandHandler
        composer.onMarkedText = { [weak self] text in self?.showPreview(text) }
        composer.anchor = { [weak window, weak preview] in
            guard let window, let preview else { return .zero }
            return window.convertToScreen(preview.frame)
        }
        content.addSubview(composer)
        self.composer = composer

        let center = NotificationCenter.default
        let update: @Sendable (Notification) -> Void = { [weak self] _ in
            DispatchQueue.main.async { self?.refreshReady() }
        }
        observers = [
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: nil, using: update),
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: nil, using: update),
            center.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: nil,
                using: update
            ),
            center.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: nil,
                using: update
            ),
        ]
    }

    func tearDownKeyboard() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        keyboard.update { $0 = KeyboardState() }
        composer?.removeFromSuperview()
        preview?.removeFromSuperview()
        composer = nil
        preview = nil
    }

    func focusComposer() {
        if let window, let composer {
            window.makeFirstResponder(composer)
        }
        refreshReady()
    }

    func refreshReady() {
        let ready = window?.isKeyWindow == true && NSApplication.shared.isActive && composer != nil
        keyboard.update { $0.ready = ready }
    }

    func showPreview(_ text: String) {
        guard let preview, let content = window?.contentView else { return }
        preview.isHidden = text.isEmpty
        guard !text.isEmpty else { return }
        preview.stringValue = " \(text) "
        preview.sizeToFit()
        preview.setFrameOrigin(NSPoint(x: (content.bounds.width - preview.frame.width) / 2, y: 80))
    }
}

private enum InputSource {
    /// True when the selected input source is an input method or mode (Vietnamese Telex, Japanese, ...), false for a
    /// plain keyboard layout such as ABC. Main thread.
    static func composesText() -> Bool {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceType)
        else { return false }
        let type = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
        return type != (kTISTypeKeyboardLayout as String)
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
    static let blankSize = NSSize(width: 16, height: 16)
    static let blank = NSCursor(image: NSImage(size: blankSize), hotSpot: .zero)

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: Self.blank)
    }
}
