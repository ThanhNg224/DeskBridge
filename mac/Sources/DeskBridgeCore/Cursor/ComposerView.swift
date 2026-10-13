import AppKit

/// An invisible text input client in the shield window. While a Mac input method (Vietnamese Telex, ...) is selected
/// the event tap lets text keys through to this view instead of sending them to the phone; macOS composes the word,
/// and the committed text goes to the phone (`onText`). Marked (still being composed) text is only reported through
/// `onMarkedText`, for the small preview label. Keys the input method hands back (`doCommand`) are sent as plain key
/// presses (`onCommand`).
final class ComposerView: NSView, @preconcurrency NSTextInputClient {
    var onText: (@Sendable (String) -> Void)?
    var onCommand: (@Sendable (UInt16, UInt64) -> Void)?
    var onMarkedText: ((String) -> Void)?
    /// Where the marked text is shown (screen coordinates): input method candidate windows open there.
    var anchor: (() -> NSRect)?

    private let keyboard: KeyboardStateBox
    private var marked = ""
    private var lastKey: (code: UInt16, flags: UInt64)?

    init(keyboard: KeyboardStateBox) {
        self.keyboard = keyboard
        super.init(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("not used")
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func keyDown(with event: NSEvent) {
        lastKey = (event.keyCode, UInt64(event.modifierFlags.rawValue))
        interpretKeyEvents([event])
    }

    override func keyUp(with _: NSEvent) {}

    private func setMarked(_ text: String) {
        marked = text
        keyboard.update { $0.composing = !text.isEmpty }
        onMarkedText?(text)
    }

    // MARK: - NSTextInputClient

    func insertText(_ string: Any, replacementRange _: NSRange) {
        setMarked("")
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        if !text.isEmpty {
            onText?(text)
        }
    }

    func setMarkedText(_ string: Any, selectedRange _: NSRange, replacementRange _: NSRange) {
        setMarked((string as? NSAttributedString)?.string ?? (string as? String) ?? "")
    }

    /// The input method accepts the marked text as it is.
    func unmarkText() {
        let text = marked
        setMarked("")
        if !text.isEmpty {
            onText?(text)
        }
    }

    override func doCommand(by _: Selector) {
        if let lastKey {
            onCommand?(lastKey.code, lastKey.flags)
        }
    }

    func hasMarkedText() -> Bool {
        !marked.isEmpty
    }

    func markedRange() -> NSRange {
        marked.isEmpty ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: marked.utf16.count)
    }

    func selectedRange() -> NSRange {
        NSRange(location: marked.utf16.count, length: 0)
    }

    func attributedSubstring(forProposedRange _: NSRange, actualRange _: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    func firstRect(forCharacterRange _: NSRange, actualRange _: NSRangePointer?) -> NSRect {
        anchor?() ?? .zero
    }

    func characterIndex(for _: NSPoint) -> Int {
        0
    }
}
