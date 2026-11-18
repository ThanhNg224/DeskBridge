import AppKit
import os

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let mirrorLog = Logger(subsystem: "com.deskbridge.app", category: "mirror")
    weak var model: AppModel?
    private var waitingToQuit = false

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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if waitingToQuit {
            return .terminateLater
        }
        guard let closing = model?.prepareToQuit() else { return .terminateNow }
        waitingToQuit = true
        Task {
            await closing.value
            finishQuit(sender)
        }
        Task {
            try? await Task.sleep(for: .seconds(2))
            guard waitingToQuit else { return }
            Self.mirrorLog.error("Timed out confirming mirror process exit")
            finishQuit(sender)
        }
        return .terminateLater
    }

    private func finishQuit(_ sender: NSApplication) {
        guard waitingToQuit else { return }
        waitingToQuit = false
        sender.reply(toApplicationShouldTerminate: true)
    }
}
