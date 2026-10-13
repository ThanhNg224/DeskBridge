import SwiftUI

@main
struct DeskBridgeApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        // A normal window (opens at launch and from the Dock) so the app is discoverable...
        Window("DeskBridge", id: "main") {
            ContentView(model: model)
                .onAppear { NSApplication.shared.activate(ignoringOtherApps: true) }
        }
        .windowResizability(.contentSize)

        // ...plus the menu bar item for everyday use.
        MenuBarExtra {
            ContentView(model: model, showsWindowButton: true)
        } label: {
            Image(nsImage: BrandIcon.menuBar(model.phase))
        }
        .menuBarExtraStyle(.window)
    }
}
