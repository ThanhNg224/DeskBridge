import DeskBridgeCore
import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel
    var showsWindowButton = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            header
            Form {
                if model.needsAccessibility {
                    Section("Permissions") {
                        Button("Open Accessibility Settings") { Permissions.openSettings(.accessibility) }
                        Button("Open Input Monitoring Settings") { Permissions.openSettings(.inputMonitoring) }
                    }
                }

                Section("Layout") {
                    Picker("Android is on the", selection: $model.prefs.edge) {
                        Text("Left").tag(ScreenEdge.left)
                        Text("Right").tag(ScreenEdge.right)
                        Text("Top").tag(ScreenEdge.top)
                        Text("Bottom").tag(ScreenEdge.bottom)
                    }
                    .pickerStyle(.segmented)
                }

                Section("Mouse") {
                    slider("Pointer speed", value: $model.prefs.pointerSpeed, range: 0.5 ... 4)
                    Toggle("Right click = Back", isOn: $model.prefs.rightClickIsBack)
                }

                Section("Scrolling") {
                    slider("Scroll speed", value: $model.prefs.scrollSpeed, range: 0.25 ... 4)
                    Toggle("Invert scroll direction", isOn: $model.prefs.invertScroll)
                }

                Section("Keyboard") {
                    Toggle("⌘ acts as Ctrl (⌘C, ⌘V, ⌘A)", isOn: $model.prefs.commandIsControl)
                }

                Section("General") {
                    Toggle("Launch at login", isOn: $model.launchAtLogin)
                }
            }
            .formStyle(.grouped)
            footer
        }
        .frame(width: 400, height: 640)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text("DeskBridge").font(.title2.weight(.semibold))
                HStack(alignment: .top, spacing: 6) {
                    Circle().fill(statusColor).frame(width: 8, height: 8).padding(.top, 5)
                    Text(model.status)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Toggle("Enabled", isOn: $model.isEnabled)
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 6)
    }

    private var footer: some View {
        HStack {
            Text("Release control: ⌃⌥⌘⎋").font(.caption).foregroundStyle(.secondary)
            Spacer()
            if showsWindowButton {
                Button("Show Window") {
                    openWindow(id: "main")
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
            }
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var statusColor: Color {
        switch model.phase {
        case .paused: .gray
        case .searching: .orange
        case .connected: .green
        case .controlling: .blue
        }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range)
                Text(value.wrappedValue, format: .number.precision(.fractionLength(1)))
                    .monospacedDigit()
                    .frame(width: 30, alignment: .trailing)
            }
            .frame(width: 210)
        }
    }
}
