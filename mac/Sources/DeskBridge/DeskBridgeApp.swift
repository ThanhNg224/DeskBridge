import SwiftUI

@main
struct DeskBridgeApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(model: model)
        } label: {
            Image(nsImage: BrandIcon.menuBar(model.phase))
                .accessibilityLabel(model.status)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
        }
    }
}
