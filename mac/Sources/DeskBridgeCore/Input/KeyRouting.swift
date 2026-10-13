import CoreGraphics
import os

/// What the keyboard side of a visit looks like right now; written on the main thread (shield window, input method),
/// read by the event tap thread.
struct KeyboardState: Equatable, Sendable {
    /// The selected input source composes text (Vietnamese Telex/VNI, Japanese, Chinese, ...), not a plain layout.
    var imeActive = false
    /// Our shield window is the key window of the active app, so it can take the keys.
    var ready = false
    /// An input method has marked (not yet committed) text.
    var composing = false
}

final class KeyboardStateBox: Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: KeyboardState())

    func read() -> KeyboardState {
        lock.withLock { $0 }
    }

    func update(_ change: (inout KeyboardState) -> Void) {
        lock.withLockUnchecked { change(&$0) }
    }
}

/// Which keys, while Android has control, go to the Mac input method (through our shield window) instead of straight
/// to the phone as key presses.
enum KeyRouting {
    /// Only with a composing input method, only when our window can really take the keys (otherwise they would land
    /// in whatever app is in front), never with Cmd/Ctrl (shortcuts, the release chord). Text keys start or extend a
    /// word; while a word is being composed every key goes (Backspace, Return, arrows, candidate selection).
    static func deliversToMac(keyCode: UInt16, flags: CGEventFlags, state: KeyboardState) -> Bool {
        guard state.imeActive, state.ready, !flags.contains(.maskCommand), !flags.contains(.maskControl) else {
            return false
        }
        return state.composing || isTextKey(keyCode)
    }

    /// Letters, digits, punctuation and space (Android KEYCODE_0..9, A..Z, comma, period, space, grave..slash).
    static func isTextKey(_ keyCode: UInt16) -> Bool {
        guard let android = KeyMapper.androidKeyCode(forMacKeyCode: keyCode) else { return false }
        return (7 ... 16).contains(android) || (29 ... 56).contains(android) || android == 62
            || (68 ... 76).contains(android)
    }
}
