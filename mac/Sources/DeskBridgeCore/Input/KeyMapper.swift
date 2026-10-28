import Carbon.HIToolbox
import CoreGraphics

public enum KeyMapper {
    public static let backKeyCode: Int32 = 4 // KEYCODE_BACK

    /// Mac virtual keycode -> Android KEYCODE_*. Keys not listed are not forwarded.
    static let table: [Int: Int32] = [
        kVK_ANSI_A: 29, kVK_ANSI_B: 30, kVK_ANSI_C: 31, kVK_ANSI_D: 32, kVK_ANSI_E: 33,
        kVK_ANSI_F: 34, kVK_ANSI_G: 35, kVK_ANSI_H: 36, kVK_ANSI_I: 37, kVK_ANSI_J: 38,
        kVK_ANSI_K: 39, kVK_ANSI_L: 40, kVK_ANSI_M: 41, kVK_ANSI_N: 42, kVK_ANSI_O: 43,
        kVK_ANSI_P: 44, kVK_ANSI_Q: 45, kVK_ANSI_R: 46, kVK_ANSI_S: 47, kVK_ANSI_T: 48,
        kVK_ANSI_U: 49, kVK_ANSI_V: 50, kVK_ANSI_W: 51, kVK_ANSI_X: 52, kVK_ANSI_Y: 53,
        kVK_ANSI_Z: 54,
        kVK_ANSI_0: 7, kVK_ANSI_1: 8, kVK_ANSI_2: 9, kVK_ANSI_3: 10, kVK_ANSI_4: 11,
        kVK_ANSI_5: 12, kVK_ANSI_6: 13, kVK_ANSI_7: 14, kVK_ANSI_8: 15, kVK_ANSI_9: 16,
        kVK_ANSI_Grave: 68, kVK_ANSI_Minus: 69, kVK_ANSI_Equal: 70,
        kVK_ANSI_LeftBracket: 71, kVK_ANSI_RightBracket: 72, kVK_ANSI_Backslash: 73,
        kVK_ANSI_Semicolon: 74, kVK_ANSI_Quote: 75, kVK_ANSI_Slash: 76,
        kVK_ANSI_Comma: 55, kVK_ANSI_Period: 56,
        kVK_Return: 66, kVK_Tab: 61, kVK_Space: 62, kVK_Delete: 67, kVK_ForwardDelete: 112,
        kVK_Escape: 111,
        kVK_LeftArrow: 21, kVK_RightArrow: 22, kVK_UpArrow: 19, kVK_DownArrow: 20,
        kVK_Home: 122, kVK_End: 123, kVK_PageUp: 92, kVK_PageDown: 93,
        kVK_F1: 131, kVK_F2: 132, kVK_F3: 133, kVK_F4: 134, kVK_F5: 135, kVK_F6: 136,
        kVK_F7: 137, kVK_F8: 138, kVK_F9: 139, kVK_F10: 140, kVK_F11: 141, kVK_F12: 142,
    ]

    public static func androidKeyCode(forMacKeyCode code: UInt16) -> Int32? {
        table[Int(code)]
    }

    /// Ctrl is Android Ctrl. Cmd is Android Ctrl too (Cmd+C / Cmd+V work) unless `commandIsControl`
    /// is false, in which case it becomes the Android Meta key.
    public static func androidMeta(forFlags rawFlags: UInt64, commandIsControl: Bool = true) -> Int32 {
        let flags = CGEventFlags(rawValue: rawFlags)
        var meta: Int32 = 0
        if flags.contains(.maskShift) {
            meta |= 0x1 | 0x40
        } // META_SHIFT_ON | META_SHIFT_LEFT_ON
        if flags.contains(.maskAlternate) {
            meta |= 0x2 | 0x10
        } // META_ALT_ON | META_ALT_LEFT_ON
        if flags.contains(.maskControl) || (commandIsControl && flags.contains(.maskCommand)) {
            meta |= 0x1000 | 0x2000 // META_CTRL_ON | META_CTRL_LEFT_ON
        }
        if !commandIsControl, flags.contains(.maskCommand) {
            meta |= 0x10000 | 0x20000 // META_META_ON | META_META_LEFT_ON
        }
        return meta
    }

    /// ⌃⌥⌘⎋ hands control back to the Mac from any state.
    public static func isReleaseChord(keyCode: UInt16, flags rawFlags: UInt64) -> Bool {
        let flags = CGEventFlags(rawValue: rawFlags)
        return Int(keyCode) == kVK_Escape
            && flags.contains(.maskControl) && flags.contains(.maskAlternate) && flags.contains(.maskCommand)
    }
}

/// Tracks shortcut key downs so releasing Option first still releases the same Android key.
struct ShortcutKeys {
    private var pressed: [UInt16: Int32] = [:]

    mutating func route(code: UInt16, down: Bool, flags: CGEventFlags) -> Int32? {
        if !down {
            return pressed.removeValue(forKey: code)
        }
        if let key = pressed[code] {
            return key
        }
        guard flags.contains(.maskAlternate),
              flags.intersection([.maskCommand, .maskControl, .maskShift]).isEmpty else { return nil }
        let key: Int32
        switch Int(code) {
        case kVK_ANSI_H: key = 3 // HOME
        case kVK_ANSI_B: key = 4 // BACK
        case kVK_ANSI_R: key = 187 // APP_SWITCH
        case kVK_ANSI_L: key = 223 // SLEEP
        case kVK_UpArrow: key = 24 // VOLUME_UP
        case kVK_DownArrow: key = 25 // VOLUME_DOWN
        default: return nil
        }
        pressed[code] = key
        return key
    }
}

/// Android's task switcher holds Alt until Option is released. Only the switcher's keys are forwarded.
struct AppSwitcher {
    struct Key: Equatable {
        let code: Int32
        let down: Bool
        let meta: Int32
    }

    private static let alt: Int32 = 57
    private static let tab: Int32 = 61
    private static let altMeta: Int32 = 0x12
    private var active = false
    private var tabDown = false

    mutating func tab(down: Bool, flags: CGEventFlags) -> [Key]? {
        if !down {
            guard tabDown else { return nil }
            tabDown = false
            return [Key(code: Self.tab, down: false, meta: active ? Self.altMeta : 0)]
        }
        if tabDown {
            return []
        }
        guard active || (flags.contains(.maskAlternate)
            && flags.intersection([.maskCommand, .maskControl, .maskShift]).isEmpty) else { return nil }
        var keys: [Key] = []
        if !active {
            active = true
            keys.append(Key(code: Self.alt, down: true, meta: Self.altMeta))
        }
        tabDown = true
        keys.append(Key(code: Self.tab, down: true, meta: Self.altMeta))
        return keys
    }

    mutating func modifiersChanged(_ flags: CGEventFlags) -> [Key] {
        guard active, !flags.contains(.maskAlternate) else { return [] }
        active = false
        return [Key(code: Self.alt, down: false, meta: 0)]
    }
}
