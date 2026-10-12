import DeskBridgeCore
import SwiftUI

struct MenuBarView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Circle().fill(model.isActive ? Color.green : Color.red).frame(width: 8, height: 8)
                Text(model.status).font(.headline).lineLimit(3)
            }

            if model.needsAccessibility {
                Button("Open Accessibility Settings") {
                    NSWorkspace.shared.open(URL(string:
                        "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
                Button("Open Input Monitoring Settings") {
                    NSWorkspace.shared.open(URL(string:
                        "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
                }
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

            Text("Scrolling").font(.caption).foregroundStyle(.secondary)
            Toggle("Invert scroll direction", isOn: $model.prefs.invertScroll)
            VStack(alignment: .leading) {
                Text("Scroll speed \(model.prefs.scrollSpeed, specifier: "%.1f")×").font(.caption)
                Slider(value: $model.prefs.scrollSpeed, in: 0.25 ... 4)
            }

            Text("Keyboard").font(.caption).foregroundStyle(.secondary)
            Toggle("⌘ acts as Ctrl (⌘C / ⌘V / ⌘A)", isOn: $model.prefs.commandIsControl)

            Text("General").font(.caption).foregroundStyle(.secondary)
            Toggle("Launch at login", isOn: $model.launchAtLogin)
            Text("Release control: ⌃⌥⌘⎋").font(.caption).foregroundStyle(.secondary)

            Divider()

            Button("Show Window") {
                openWindow(id: "main")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }

            Button("Quit DeskBridge") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding()
        .frame(width: 280)
    }
}
