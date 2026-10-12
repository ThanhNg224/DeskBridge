import SwiftUI

@main
struct DeskBridgeApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        // A normal window (opens at launch and from the Dock) so the app is discoverable...
        Window("DeskBridge", id: "main") {
            MenuBarView(model: model)
                .onAppear { NSApplication.shared.activate(ignoringOtherApps: true) }
        }
        .windowResizability(.contentSize)

        // ...plus the menu bar item for everyday use.
        MenuBarExtra("DeskBridge", systemImage: "display") {
            MenuBarView(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}
