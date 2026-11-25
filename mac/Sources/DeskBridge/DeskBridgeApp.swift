import SwiftUI

enum AppAppearance: String {
    case system, light, dark

    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

@main
struct DeskBridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @AppStorage("appAppearance") private var appearance = AppAppearance.system
    @State private var settingsPane = SettingsPane.connection

    var body: some Scene {
        // Opens at launch and from the Dock icon, so the app is never silently invisible.
        Window("DeskBridge", id: AppWindow.mainID) {
            SettingsView(model: model, pane: $settingsPane, appearance: $appearance)
                .modifier(RegisterWindowOpener())
                .onAppear { appDelegate.model = model }
        }
        .onChange(of: appearance, initial: true) { NSApp.appearance = appearance.appearance }
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
