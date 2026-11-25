import SwiftUI

@main
struct DeskBridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @State private var settingsPane = SettingsPane.connection

    var body: some Scene {
        // Opens at launch and from the Dock icon, so the app is never silently invisible.
        Window("DeskBridge", id: AppWindow.mainID) {
            SettingsView(model: model, pane: $settingsPane)
                .modifier(RegisterWindowOpener())
                .onAppear { appDelegate.model = model }
        }
        .defaultSize(width: 800, height: 660)
        .windowResizability(.contentMinSize) // user can resize; the content sets the minimum

        MenuBarExtra {
            MenuBarView(model: model, openSetup: {
                settingsPane = .connection
                AppWindow.show()
            })
            .onAppear { appDelegate.model = model }
        } label: {
            Image(nsImage: BrandIcon.menuBar(model.phase))
                .accessibilityLabel(model.status)
        }
        .menuBarExtraStyle(.window)
    }
}
