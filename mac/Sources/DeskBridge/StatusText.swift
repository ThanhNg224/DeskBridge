import DeskBridgeCore
import Foundation

/// User-facing text for the app's states. The English text is the localization key (see vi.lproj).
enum StatusText {
    static let searching = String(localized: "Looking for a device…")
    static let paused = String(localized: "Paused")
    static let noDevice = String(localized: "Connect an Android phone via USB or Wi-Fi with debugging enabled")
    static let needsAccessibility = String(localized: "DeskBridge needs Accessibility access")
    static let checkInputMonitoring = String(localized: "Check Input Monitoring to enable mouse and keyboard control.")
    static let jarMissing = String(localized: "Reinstall DeskBridge to restore the missing phone connection files.")
    static let adbFailure =
        String(localized: "Android tools could not reach the phone. Check its connection and try again.")
    static let preparingConnection = String(localized: "Preparing connection…")
    static let connectionCancelled = String(localized: "Connection cancelled")

    static func choosePhone(count: Int) -> String {
        String(localized: "\(count) phones are connected. Choose one in Settings.")
    }

    static func connecting(_ name: String) -> String {
        String(localized: "Connecting to \(name)…")
    }

    static func connected(_ name: String) -> String {
        String(localized: "Connected to \(name)")
    }

    static func waiting(_ name: String) -> String {
        String(localized: "Waiting for \(name)")
    }

    static func reconnecting(_ name: String) -> String {
        String(localized: "Reconnecting to \(name)…")
    }

    static func disconnected(_ name: String) -> String {
        String(localized: "Disconnected from \(name)")
    }

    static func controlling(_ name: String) -> String {
        String(localized: "Controlling \(name). Press ⌃⎋ to give the mouse back to the Mac.")
    }

    static func notAuthorized(_ state: String) -> String {
        String(localized: "Allow this Mac on the phone (\(state))")
    }

    static func ended(_ reason: SessionEndReason, accessibilityGranted: Bool) -> String {
        if reason.isInjectionDenied {
            return String(localized: "The phone refused input. On Xiaomi, turn on “USB debugging (Security settings)”.")
        }
        switch reason {
        case .stopped: return paused
        case .captureDenied: return accessibilityGranted ? checkInputMonitoring : needsAccessibility
        case .deviceSilent,
             .connectionLost: return String(
                localized: "The phone disconnected. Check the cable or Wi-Fi, then try again."
            )
        case .protocolError: return String(localized: "The phone sent an unexpected reply. Reconnect it and try again.")
        case .adbFailed: return adbFailure
        }
    }

    static func details(for reason: SessionEndReason) -> String? {
        switch reason {
        case let .adbFailed(detail), let .connectionLost(detail), let .protocolError(detail):
            diagnostic(detail)
        default: nil
        }
    }

    static func diagnostic(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(2048))
    }
}
