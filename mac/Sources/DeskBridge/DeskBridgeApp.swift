import SwiftUI

@main
struct DeskBridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        // Opens at launch and from the Dock icon, so the app is never silently invisible.
        Window("DeskBridge", id: AppWindow.mainID) {
            SettingsView(model: model)
                .modifier(RegisterWindowOpener())
        }
        .windowResizability(.contentSize)

        MenuBarExtra {
            MenuBarView(model: model)
        } label: {
            Image(nsImage: BrandIcon.menuBar(model.phase))
                .accessibilityLabel(model.status)
        }
        .menuBarExtraStyle(.window)
    }
}
