import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Within this time after boot a launch is assumed to come from "Launch at login": stay in the menu bar.
    private static let loginLaunchWindow: TimeInterval = 300

    func applicationDidFinishLaunching(_: Notification) {
        let launchedAtLogin = LoginItem.isEnabled && ProcessInfo.processInfo.systemUptime < Self.loginLaunchWindow
        guard launchedAtLogin else { return }
        // SwiftUI opens the window at launch; close it again so a login start is quiet.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            NSApplication.shared.windows.filter(\.canBecomeMain).forEach { $0.close() }
        }
    }

    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            AppWindow.show()
        }
        return true
    }
}
