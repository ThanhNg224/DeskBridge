import AppKit

enum SettingsWindow {
    /// Brings the Settings window to the front. A menu-bar-only app is not active, so activate first.
    @MainActor
    static func open() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}
