import AppKit
import ApplicationServices

@MainActor enum ScrcpyWindow {
    /// Nil means the first mirror window never appeared.
    static func show(pid: pid_t, executable: URL, waitForWindow: Bool) async -> Bool? {
        if waitForWindow {
            let deadline = ContinuousClock.now + .seconds(8)
            while !hasVisibleWindow(pid: pid) {
                guard ContinuousClock.now < deadline else { return nil }
                do { try await Task.sleep(for: .milliseconds(80)) } catch { return nil }
            }
        }
        guard !Task.isCancelled, let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
              app.executableURL?.resolvingSymlinksInPath() == executable.resolvingSymlinksInPath()
        else {
            return false
        }
        if NSApplication.shared.isActive {
            NSApplication.shared.yieldActivation(to: app)
        }
        _ = app.activate()
        if !app.isActive || !hasVisibleWindow(pid: pid) {
            restoreWindow(pid: pid)
        }
        do { try await Task.sleep(for: .milliseconds(180)) } catch { return false }
        return app.isActive && hasVisibleWindow(pid: pid)
    }

    private static func hasVisibleWindow(pid: pid_t) -> Bool {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return windows.contains {
            $0[kCGWindowOwnerPID as String] as? pid_t == pid && $0[kCGWindowLayer as String] as? Int == 0
        }
    }

    private static func restoreWindow(pid: pid_t) {
        guard AXIsProcessTrusted() else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let window = (value as? [AXUIElement])?.first else { return }
        AXUIElementSetMessagingTimeout(window, 0.15)
        _ = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        _ = AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }
}
