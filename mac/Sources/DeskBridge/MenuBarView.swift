import DeskBridgeCore
import SwiftUI

struct MenuBarView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Circle().fill(model.isActive ? Color.green : Color.red).frame(width: 8, height: 8)
                Text(model.status).font(.headline).lineLimit(3)
            }

            Divider()

            Picker("Android is on the", selection: $model.prefs.edge) {
                Text("Left").tag(ScreenEdge.left)
                Text("Right").tag(ScreenEdge.right)
            }
            .pickerStyle(.segmented)

            Toggle("Right click = Back", isOn: $model.prefs.rightClickIsBack)

            VStack(alignment: .leading) {
                Text("Pointer speed \(model.prefs.pointerSpeed, specifier: "%.1f")×").font(.caption)
                Slider(value: $model.prefs.pointerSpeed, in: 0.5 ... 4)
            }

            Divider()

            Button("Quit DeskBridge") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding()
        .frame(width: 280)
    }
}
