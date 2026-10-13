import AppKit

/// Makes sure launching the app (or clicking its Dock icon again) always shows something.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Within this time after boot a launch is assumed to come from "Launch at login": stay quiet.
    private static let loginLaunchWindow: TimeInterval = 300

    func applicationDidFinishLaunching(_: Notification) {
        let launchedAtLogin = LoginItem.isEnabled && ProcessInfo.processInfo.systemUptime < Self.loginLaunchWindow
        guard !launchedAtLogin else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { SettingsWindow.open() }
    }

    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        SettingsWindow.open()
        return true
    }
}
