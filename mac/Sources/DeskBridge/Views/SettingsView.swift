import DeskBridgeCore
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            StatusHeader(model: model)
            form
        }
        .frame(width: 440, height: 680)
    }

    private var form: some View {
        Form {
            if !model.setup.isComplete {
                SetupChecklist(setup: model.setup)
            }

            if model.setup.phones.count > 1 {
                Section("Phone") {
                    Picker("Use this phone", selection: $model.prefs.preferredSerial) {
                        Text("Choose…").tag(String?.none)
                        ForEach(model.setup.phones, id: \.serial) { phone in
                            Text(phone.displayName).tag(String?.some(phone.serial))
                        }
                    }
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
                SpeedSlider(title: "Pointer speed", value: $model.prefs.pointerSpeed, range: 0.5 ... 4)
                Toggle("Right click = Back", isOn: $model.prefs.rightClickIsBack)
            }

            Section("Scrolling") {
                SpeedSlider(title: "Scroll speed", value: $model.prefs.scrollSpeed, range: 0.25 ... 4)
                Toggle("Invert scroll direction", isOn: $model.prefs.invertScroll)
            }

            Section("Keyboard") {
                Toggle("⌘ acts as Ctrl (⌘C, ⌘V, ⌘A)", isOn: $model.prefs.commandIsControl)
            }

            Section("General") {
                Toggle("Launch at login", isOn: $model.launchAtLogin)
                Toggle("Show icon in the Dock", isOn: $model.showDockIcon)
            }
        }
        .formStyle(.grouped)
    }
}

private struct SpeedSlider: View {
    let title: LocalizedStringKey
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: $value, in: range)
                Text(value, format: .number.precision(.fractionLength(1)))
                    .monospacedDigit()
                    .frame(width: 32, alignment: .trailing)
            }
            .frame(width: 220)
        }
    }
}
