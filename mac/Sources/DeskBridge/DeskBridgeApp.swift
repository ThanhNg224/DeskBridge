import SwiftUI

@main
struct DeskBridgeApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("DeskBridge", systemImage: "display") {
            MenuBarView(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}
