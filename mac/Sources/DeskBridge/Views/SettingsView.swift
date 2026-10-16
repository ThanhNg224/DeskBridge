import DeskBridgeCore
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            StatusHeader(model: model)
            form
        }
        .frame(minWidth: 400, idealWidth: 440, maxWidth: 700, minHeight: 420, idealHeight: 680)
    }

    private var form: some View {
        Form {
            if !model.setup.isComplete {
                SetupChecklist(setup: model.setup)
            }

            if !model.setup.phones.isEmpty {
                Section("Phone") {
                    if model.setup.phones.count > 1 {
                        Picker("Use this phone", selection: $model.prefs.preferredSerial) {
                            Text("Choose…").tag(String?.none)
                            ForEach(model.setup.phones, id: \.serial) { phone in
                                Text("\(phone.displayName) [\(phone.isWireless ? "Wi-Fi" : "USB")]")
                                    .tag(String?.some(phone.serial))
                            }
                        }
                    } else if let phone = model.setup.phones.first {
                        LabeledContent(
                            "Connected phone",
                            value: "\(phone.displayName) [\(phone.isWireless ? "Wi-Fi" : "USB")]"
                        )
                    }

                    if let active = activePhone {
                        if !active.isWireless {
                            HStack {
                                Button("Switch to Wi-Fi") {
                                    model.switchToWireless(serial: active.serial)
                                }
                                .disabled(model.isSwitchingToWireless)
                                if model.isSwitchingToWireless {
                                    ProgressView().controlSize(.small)
                                }
                            }
                        } else {
                            Button("Disconnect Wi-Fi", role: .destructive) {
                                model.disconnectWireless(serial: active.serial)
                            }
                        }
                    }
                }
            }

            Section("Connect via Wi-Fi") {
                HStack {
                    TextField("IP Address", text: $model.wirelessIP)
                        .textFieldStyle(.roundedBorder)
                    TextField("Port", text: $model.wirelessPort)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                    Button("Connect") {
                        model.connectWireless()
                    }
                    .disabled(model.wirelessIP.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model
                        .isConnectingWireless)
                    if model.isConnectingWireless {
                        ProgressView().controlSize(.small)
                    }
                }
                if let error = model.wirelessErrorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
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
                Toggle("Share the clipboard (text)", isOn: $model.prefs.shareClipboard)
            }

            Section("General") {
                Toggle("Launch at login", isOn: $model.launchAtLogin)
                Toggle("Show icon in the Dock", isOn: $model.showDockIcon)
            }
        }
        .formStyle(.grouped)
    }

    private var activePhone: AdbDevice? {
        if let preferred = model.prefs.preferredSerial {
            return model.setup.phones.first(where: { $0.serial == preferred })
        }
        return model.setup.phones.first
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
