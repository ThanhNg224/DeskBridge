import DeskBridgeCore
import Foundation

/// User-facing text for the app's states. The English text is the localization key (see vi.lproj).
enum StatusText {
    static let searching = String(localized: "Looking for a device…")
    static let paused = String(localized: "Paused")
    static let noDevice = String(localized: "Connect an Android phone via USB or Wi-Fi with debugging enabled")
    static let needsAccessibility = String(localized: "DeskBridge needs Accessibility access")
    static let jarMissing = String(localized: "The Android server file is missing. Run scripts/build_server.sh")

    static func choosePhone(count: Int) -> String {
        String(localized: "\(count) phones are connected. Choose one in Settings.")
    }

    static func connecting(_ name: String) -> String {
        String(localized: "Connecting to \(name)…")
    }

    static func connected(_ name: String) -> String {
        String(localized: "Connected to \(name)")
    }

    static func controlling(_ name: String) -> String {
        String(localized: "Controlling \(name). Press ⌃⌥⌘⎋ to give the mouse back to the Mac.")
    }

    static func notAuthorized(_ state: String) -> String {
        String(localized: "Allow this Mac on the phone (\(state))")
    }

    static func ended(_ reason: SessionEndReason) -> String {
        if reason.isInjectionDenied {
            return String(localized: "The phone refused input. On Xiaomi, turn on “USB debugging (Security settings)”.")
        }
        switch reason {
        case .stopped: return paused
        case .captureDenied: return needsAccessibility
        case .deviceSilent: return String(localized: "The phone stopped responding")
        case .protocolError: return String(localized: "Unexpected reply from the phone")
        case let .adbFailed(detail): return detail
        case let .connectionLost(log):
            return log.isEmpty ? String(localized: "The connection to the phone was lost") : log
        }
    }
}
