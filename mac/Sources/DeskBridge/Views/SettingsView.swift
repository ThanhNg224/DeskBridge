import DeskBridgeCore
import SwiftUI

enum SettingsPane: CaseIterable {
    case connection, controls, shortcuts, general

    var title: LocalizedStringKey {
        switch self {
        case .connection: "Connection"
        case .controls: "Controls"
        case .shortcuts: "Shortcuts"
        case .general: "General"
        }
    }
}

struct SettingsView: View {
    @Bindable var model: AppModel
    @Binding var pane: SettingsPane
    @State private var showingManualWifi = false
    @State private var confirmingADBRestart = false
    @State private var detectedPhoneToConfirm: AppModel.DetectedPhone?
    @State private var confirmingDetectedPhone = false
    @State private var confirmingAutoWifi = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("Settings section", selection: $pane) {
                ForEach(SettingsPane.allCases, id: \.self) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Settings section")
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
            Divider()

            StatusHeader(model: model)
            if pane != .connection, model.isOperatingWireless || model.wirelessErrorMessage != nil {
                HStack(spacing: 8) {
                    if model.isOperatingWireless {
                        ProgressView().controlSize(.small)
                        wirelessProgress
                    } else if let error = model.wirelessErrorMessage {
                        Label(error, systemImage: "exclamationmark.circle")
                    }
                    Spacer()
                    Button("Show connection") { pane = .connection }
                }
                .font(.callout)
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
            }
            form
        }
        .frame(minWidth: 480, idealWidth: 560, maxWidth: 760, minHeight: 420, idealHeight: 560)
        .onChange(of: model.wirelessIP) { model.wirelessErrorMessage = nil }
        .onChange(of: model.wirelessPort) { model.wirelessErrorMessage = nil }
        .alert("Restart ADB server?", isPresented: $confirmingADBRestart) {
            Button("Cancel", role: .cancel) {}
            Button("Restart ADB") { model.restartADB() }
        } message: {
            Text("This temporarily disconnects all devices and other apps using ADB. They may need to reconnect.")
        }
        .alert("Use detected phone?", isPresented: $confirmingDetectedPhone) {
            Button("Cancel", role: .cancel) {}
            Button("Use phone") {
                if let phone = detectedPhoneToConfirm {
                    model.useDetectedPhone(phone)
                }
            }
        } message: {
            Text("A different phone is using this connection. Switch control to it?")
        }
        .alert("Automatically prepare Wi-Fi?", isPresented: $confirmingAutoWifi) {
            Button("Cancel", role: .cancel) {}
            Button("Enable") { model.prefs.autoPrepareWifi = true }
        } message: {
            Text(
                "This may briefly restart Android debugging and enables unencrypted ADB on the local network. The phone can keep that access enabled after this setting is off. Use only on trusted networks."
            )
        }
    }

    private var form: some View {
        Form {
            switch pane {
            case .connection:
                phoneSection
                if !model.setup.isComplete {
                    SetupChecklist(model: model)
                }
                wirelessSection
            case .controls:
                controls
            case .shortcuts:
                shortcuts
            case .general:
                general
            }
        }
        .formStyle(.grouped)
        .id(pane)
    }

    @ViewBuilder
    private var controls: some View {
        Section("Phone position") {
            Picker("Android is on the", selection: $model.prefs.edge) {
                Text("Left").tag(ScreenEdge.left)
                Text("Right").tag(ScreenEdge.right)
                Text("Top").tag(ScreenEdge.top)
                Text("Bottom").tag(ScreenEdge.bottom)
            }
            .pickerStyle(.segmented)
        }

        Section("Mouse & scrolling") {
            SpeedSlider(title: "Pointer speed", value: $model.prefs.pointerSpeed, range: 0.5 ... 4)
            Toggle("Right click = Back", isOn: $model.prefs.rightClickIsBack)
            SpeedSlider(title: "Scroll speed", value: $model.prefs.scrollSpeed, range: 0.25 ... 4)
            Toggle("Invert scroll direction", isOn: $model.prefs.invertScroll)
        }

        Section("Keyboard & clipboard") {
            Toggle("⌘ acts as Ctrl (⌘C, ⌘V, ⌘A)", isOn: $model.prefs.commandIsControl)
            Toggle("Share the clipboard (text)", isOn: $model.prefs.shareClipboard)
        }
    }

    @ViewBuilder
    private var shortcuts: some View {
        Section("Android navigation") {
            shortcutRow("Home", "⌥H")
            shortcutRow("Back", "⌥B")
            shortcutRow("Recent apps", "⌥R")
            shortcutRow("Switch apps", "⌥Tab")
            shortcutRow("Notification panel", "⌥N")
        }
        Section("Screen") {
            shortcutRow("Sleep screen", "⌥L")
            shortcutRow("Brightness up", "⌥→")
            shortcutRow("Brightness down", "⌥←")
        }
        Section("Audio & media") {
            shortcutRow("Volume up", "⌥↑")
            shortcutRow("Volume down", "⌥↓")
            shortcutRow("Mute", "⌥M")
            shortcutRow("Play/pause", "⌥P")
        }
    }

    @ViewBuilder
    private var general: some View {
        Section("Startup & Dock") {
            Toggle("Launch at login", isOn: $model.launchAtLogin)
            Toggle("Show icon in the Dock", isOn: $model.showDockIcon)
        }
        Section("Updates") {
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
                    if let detected = model.detectedDifferentPhone {
                        Button("Use detected phone…") {
                            detectedPhoneToConfirm = detected
                            confirmingDetectedPhone = true
                        }
                    }
                    if let message = model.automaticSwitchMessage {
                        Text(verbatim: message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let message = model.autoWifiStatus {
                        Text(verbatim: message).font(.caption).foregroundStyle(.secondary)
                        if !model.autoWifiInProgress {
                            Button("Retry Wi-Fi") { model.retryAutoWifi() }
                        }
                    }
                    if model.selectedPhoneHasBothTransports {
                        Picker("Connection", selection: Binding(
                            get: { model.prefs.preferredSerial ?? "" },
                            set: { model.selectTransport(serial: $0) }
                        )) {
                            ForEach(model.selectedPhoneTransports, id: \.serial) { transport in
                                Text(transport.isWireless ? "Wi-Fi" : "USB").tag(transport.serial)
                            }
                        }
                        .pickerStyle(.segmented)
                        .disabled(model.isOperatingWireless || !model.isEnabled)
                    }
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
        Section("Wi-Fi") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Automatically prepare Wi-Fi", isOn: Binding(
                    get: { model.prefs.autoPrepareWifi },
                    set: { enabled in
                        if enabled {
                            confirmingAutoWifi = true
                        } else {
                            model.prefs.autoPrepareWifi = false
                        }
                    }
                ))
                Button {
                    showingManualWifi.toggle()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: showingManualWifi ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 12)
                            .accessibilityHidden(true)
                        Text("Manual Wi-Fi")
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: 32)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(showingManualWifi ? Text("Expanded") : Text("Collapsed"))

                if showingManualWifi {
                    manualWifiFields
                        .padding(.bottom, 8)
                }

                if let error = model.wirelessErrorMessage ?? (showingManualWifi ? model.wirelessInputError : nil) {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(error, systemImage: "exclamationmark.circle")
                            .foregroundStyle(.red)
                        if model.wirelessErrorMessage != nil, let detail = model.wirelessErrorDetails {
                            Text("ADB details")
                                .foregroundStyle(.secondary)
                            Text(verbatim: detail)
                                .textSelection(.enabled)
                        }
                        if model.canRestartADB {
                            Button("Restart ADB…") { confirmingADBRestart = true }
                        }
                    }
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                }
                if model.isOperatingWireless {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        wirelessProgress
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        if !model.isRestartingADB, !model.autoWifiInProgress {
                            Button("Cancel") { model.cancelWireless() }
                                .keyboardShortcut(.cancelAction)
                        }
                    }
                }
            }
        }
    }

    private var manualWifiFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 8) {
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
                Button("Connect") { model.connectWireless() }
                    .disabled(!model.canConnectWireless)
            }
            .textFieldStyle(.roundedBorder)
            .disabled(model.isOperatingWireless)
            .onSubmit {
                if model.canConnectWireless {
                    model.connectWireless()
                }
            }

            Text(
                "Use the same Wi-Fi network. Enable automatic preparation over USB, or pair the phone outside DeskBridge."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var wirelessProgress: some View {
        if model.autoWifiInProgress {
            Text("Preparing Wi-Fi…")
        } else if model.isRestartingADB {
            Text("Restarting ADB…")
        } else {
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
