import Foundation

/// What the session does with one captured event while Android has control.
public enum RemoteAction: Equatable, Sendable {
    /// Pointer delta in Android pixels (already scaled by the pointer speed).
    case move(dx: Float, dy: Float)
    /// A ready packet; pending pointer moves are flushed before it so ordering is kept.
    case send(Data)
    /// The release chord: give control back to the Mac.
    case releaseToMac
    case ignore
}

/// Pure translation of Mac input into Android packets, driven by the user's settings.
public enum RemoteInput {
    // Android MotionEvent.BUTTON_* bits.
    private static let primary: UInt8 = 1
    private static let secondary: UInt8 = 2
    private static let tertiary: UInt8 = 4

    public static func action(for event: CapturedEvent, prefs: Settings.Values) -> RemoteAction {
        switch event {
        case let .move(dx, dy, _):
            return .move(dx: Float(dx * prefs.pointerSpeed), dy: Float(dy * prefs.pointerSpeed))
        case let .button(button, down):
            return .send(buttonPacket(button, down: down, rightClickIsBack: prefs.rightClickIsBack))
        case let .scroll(h, v):
            let factor = Float(prefs.scrollSpeed) * (prefs.invertScroll ? -1 : 1)
            return .send(ProtocolEncoder.scroll(h: Float(h) * factor, v: Float(v) * factor))
        case let .androidKey(code, down):
            return .send(ProtocolEncoder.key(code: code, down: down, meta: 0))
        case let .switchKey(code, down, meta):
            return .send(ProtocolEncoder.key(code: code, down: down, meta: meta))
        case let .key(code, down, flags):
            if down, KeyMapper.isReleaseChord(keyCode: code, flags: flags) {
                return .releaseToMac
            }
            guard let android = KeyMapper.androidKeyCode(forMacKeyCode: code) else { return .ignore }
            let meta = KeyMapper.androidMeta(forFlags: flags, commandIsControl: prefs.commandIsControl)
            return .send(ProtocolEncoder.key(code: android, down: down, meta: meta))
        }
    }

    private static func buttonPacket(_ button: MouseButton, down: Bool, rightClickIsBack: Bool) -> Data {
        switch button {
        case .left: ProtocolEncoder.button(primary, down: down)
        case .right where rightClickIsBack: ProtocolEncoder.key(code: KeyMapper.backKeyCode, down: down, meta: 0)
        case .right: ProtocolEncoder.button(secondary, down: down)
        case .other: ProtocolEncoder.button(tertiary, down: down)
        }
    }
}
