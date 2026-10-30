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
                SetupChecklist(model: model)
            }

            phoneSection
            wirelessSection

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

            Section("Android shortcuts") {
                shortcutRow("Home", "⌥H")
                shortcutRow("Back", "⌥B")
                shortcutRow("Recent apps", "⌥R")
                shortcutRow("Switch apps", "⌥Tab")
                shortcutRow("Sleep screen", "⌥L")
                shortcutRow("Volume up", "⌥↑")
                shortcutRow("Volume down", "⌥↓")
                shortcutRow("Brightness up", "⌥→")
                shortcutRow("Brightness down", "⌥←")
                shortcutRow("Notification panel", "⌥N")
                shortcutRow("Mute", "⌥M")
                shortcutRow("Play/pause", "⌥P")
            }

            Section("General") {
                Toggle("Launch at login", isOn: $model.launchAtLogin)
                Toggle("Show icon in the Dock", isOn: $model.showDockIcon)
                HStack {
                    Button("Check for updates") { model.checkForUpdates() }
                        .disabled(model.checkingUpdates)
                    if model.checkingUpdates {
                        ProgressView().controlSize(.small)
                    }
                }
                if let message = model.updateMessage {
                    Text(verbatim: message).font(.caption)
                }
                if let url = model.updateURL {
                    Link("Open download page", destination: url)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func shortcutRow(_ title: LocalizedStringKey, _ keys: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(verbatim: keys).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var phoneSection: some View {
        if !model.setup.phones.isEmpty {
            Section("Phone") {
                Picker("Use this phone", selection: Binding(
                    get: { model.prefs.preferredSerial },
                    set: { model.selectDevice(serial: $0) }
                )) {
                    Text("Choose…").tag(String?.none).disabled(true)
                    ForEach(model.setup.phones, id: \.serial) { phone in
                        VStack(alignment: .leading, spacing: 2) {
                            Label {
                                Text(verbatim: phone.connectionLabel + (
                                    phone.isReady ? "" : " · \(String(localized: "Disconnected"))"
                                ))
                            } icon: {
                                Image(systemName: phone.isWireless ? "wifi" : "cable.connector")
                            }
                            Text(phone.serial).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(String?.some(phone.serial))
                        .help(phone.serial)
                    }
                }

                if let phone = model.selectedPhone {
                    HStack(spacing: 8) {
                        Label(phone.isWireless ? "Wi-Fi" : "USB",
                              systemImage: phone.isWireless ? "wifi" : "cable.connector")
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        if phone.isWireless {
                            Button("Disconnect Wi-Fi", role: .destructive) {
                                model.disconnectWireless(serial: phone.serial)
                            }
                            .disabled(model.isOperatingWireless)
                        } else {
                            Button("Switch to Wi-Fi") {
                                model.switchToWireless(serial: phone.serial)
                            }
                            .disabled(!phone.isReady || model.isOperatingWireless)
                        }
                    }
                }
                if model.canRetryConnection {
                    Button("Retry now") { model.retryConnection() }
                }
            }
        }
    }

    private var wirelessSection: some View {
        Section("Connect via Wi-Fi") {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("IP Address").font(.callout)
                        TextField("IP Address", text: $model.wirelessIP, prompt: Text(verbatim: "192.168.1.75"))
                            .labelsHidden()
                            .accessibilityLabel("IP Address")
                    }
                    .frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Port").font(.callout)
                        TextField("Port", text: $model.wirelessPort)
                            .labelsHidden()
                            .accessibilityLabel("Port")
                    }
                    .frame(width: 80)
                }
                .textFieldStyle(.roundedBorder)
                .disabled(model.isOperatingWireless)
                .onSubmit {
                    if model.canConnectWireless {
                        model.connectWireless()
                    }
                }

                Text(
                    "Use the same Wi-Fi network. First use Switch to Wi-Fi over USB, or pair the phone outside DeskBridge."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                Group {
                    if let error = model.wirelessErrorMessage ?? model.wirelessInputError {
                        Label(error, systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(" ").font(.caption)
                    }
                }
                .frame(minHeight: 18, alignment: .topLeading)

                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .opacity(model.isOperatingWireless ? 1 : 0)
                        .accessibilityHidden(!model.isOperatingWireless)
                    wirelessProgress
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button("Connect") { model.connectWireless() }
                        .disabled(!model.canConnectWireless)
                    if model.isOperatingWireless {
                        Button("Cancel") { model.cancelWireless() }
                            .keyboardShortcut(.cancelAction)
                    }
                }
                .frame(minHeight: 24)
            }
            .padding(.vertical, 8)
            .onChange(of: model.wirelessIP) { model.wirelessErrorMessage = nil }
            .onChange(of: model.wirelessPort) { model.wirelessErrorMessage = nil }
        }
    }

    @ViewBuilder
    private var wirelessProgress: some View {
        switch model.wirelessOperation {
        case .idle: EmptyView()
        case .readingAddress: Text("Reading Wi-Fi address…")
        case .preparing: Text("Preparing Wi-Fi…")
        case .connecting: Text("Connecting to ADB…")
        case .checkingDevice: Text("Waiting for device…")
        case .startingSession: Text("Starting control session…")
        case .disconnecting: Text("Disconnecting…")
        }
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
