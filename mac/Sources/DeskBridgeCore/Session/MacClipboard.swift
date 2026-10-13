import AppKit

/// The Mac side of clipboard sharing. Text only, and only when it changed since the last hand-over
/// (`changeCount` is read once per hand-over: no polling). Used from the session queue.
final class MacClipboard: @unchecked Sendable {
    private static let hiddenTypes: [NSPasteboard.PasteboardType] = [
        NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
        NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
    ]

    private let board = NSPasteboard.general
    private var syncedChangeCount: Int?

    /// The text to give the phone, or nil when nothing new: unchanged since the last sync, not text, too large, or
    /// marked concealed/transient (password managers do that).
    func textToSend() -> String? {
        let count = board.changeCount
        guard count != syncedChangeCount else { return nil }
        syncedChangeCount = count
        let types = board.types ?? []
        guard !types.contains(where: Self.hiddenTypes.contains),
              let text = board.string(forType: .string), !text.isEmpty,
              text.utf8.count <= ProtocolEncoder.maxClipboardBytes
        else { return nil }
        return text
    }

    /// Puts the phone's text on the Mac clipboard; it will not be sent back.
    func apply(_ text: String) {
        board.clearContents()
        board.setString(text, forType: .string)
        syncedChangeCount = board.changeCount
    }
}
