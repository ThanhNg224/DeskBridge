import AppKit
import SwiftUI

/// The one window of the app (settings + setup checklist). SwiftUI opens it through `openWindow`, which only
/// views can reach, so the window's own view registers an opener here for the menu bar item and the AppDelegate.
enum AppWindow {
    static let mainID = "main"

    @MainActor static var opener: (() -> Void)?

    /// Brings the window to the front, opening it if it was closed.
    @MainActor
    static func show() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        opener?()
    }
}

struct RegisterWindowOpener: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            AppWindow.opener = { openWindow(id: AppWindow.mainID) }
        }
    }
}
