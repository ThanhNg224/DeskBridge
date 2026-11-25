import DeskBridgeCore
import SwiftUI

enum SettingsPane: CaseIterable {
    case connection, controls, shortcuts, general

    var symbol: String {
        switch self {
        case .connection: "cable.connector"
        case .controls: "slider.horizontal.3"
        case .shortcuts: "keyboard"
        case .general: "gearshape"
        }
    }

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
    @Binding var appearance: AppAppearance
    @State private var showingManualWifi = false
    @State private var confirmingADBRestart = false
    @State private var detectedPhoneToConfirm: AppModel.DetectedPhone?
    @State private var confirmingDetectedPhone = false
    @State private var confirmingAutoWifi = false

    var body: some View {
        GeometryReader { geometry in
            let hasSidebar = geometry.size.width >= 700
            HStack(spacing: 0) {
                if hasSidebar {
                    sidebar
                    Divider()
                }
                VStack(spacing: 0) {
                    if !hasSidebar {
                        compactNavigation
                        Divider()
                    }
                    detail
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(minWidth: 480, idealWidth: 800, minHeight: 440, idealHeight: 660)
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

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable().frame(width: 32, height: 32)
                    .accessibilityHidden(true)
                Text("DeskBridge").font(.headline)
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            List(selection: Binding<SettingsPane?>(
                get: { pane },
                set: {
                    if let selection = $0 {
                        pane = selection
                    }
                }
            )) {
                ForEach(SettingsPane.allCases, id: \.self) { item in
                    Label(item.title, systemImage: item.symbol)
                        .padding(.vertical, 3)
                        .tag(item)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .accessibilityLabel("Settings section")
        }
        .frame(width: 168)
        .background(.regularMaterial)
    }

    private var compactNavigation: some View {
        Picker("Settings section", selection: $pane) {
            ForEach(SettingsPane.allCases, id: \.self) { item in
                Text(item.title).tag(item)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel("Settings section")
        .controlSize(.large)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    private var detail: some View {
        VStack(spacing: 0) {
            StatusHeader(
                model: model,
                showsMirrorControls: pane == .connection && (model.setup.isComplete || phoneScreenSuspendsHandoff)
            )
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
    }

    private var form: some View {
        Form {
            switch pane {
            case .connection:
                if !model.setup.isComplete || model.installingADB {
                    SetupChecklist(model: model)
                } else if model.phase == .connected || model.phase == .controlling {
                    handoffSection
                }
                phoneSection
                connectionSection
                if let details = model.connectionErrorDetails {
                    Section {
                        DisclosureGroup("Technical details") {
                            Text(verbatim: details)
                                .textSelection(.enabled)
                        }
                    }
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

    private var phoneScreenSuspendsHandoff: Bool {
        switch model.mirrorPhase {
        case .opening, .open, .focusFailed, .closing: true
        case .idle, .notInstalled, .failed, .disconnected: false
        }
    }

    private var phonePositionPicker: some View {
        Picker("Android is on the", selection: $model.prefs.edge) {
            Text("Left").tag(ScreenEdge.left)
            Text("Right").tag(ScreenEdge.right)
            Text("Top").tag(ScreenEdge.top)
            Text("Bottom").tag(ScreenEdge.bottom)
        }
        .pickerStyle(.segmented)
    }

    private var handoffSection: some View {
        Section("Control your phone") {
            PhonePlacementView(edge: $model.prefs.edge)
            if !phoneScreenSuspendsHandoff {
                Text(handoffHint)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var handoffHint: LocalizedStringKey {
        if model.phase == .controlling {
            return "Move the pointer back past the same edge to return to your Mac."
        }
        switch model.prefs.edge {
        case .left: return "Push the pointer past the left edge to control your phone."
        case .right: return "Push the pointer past the right edge to control your phone."
        case .top: return "Push the pointer past the top edge of your main display to control your phone."
        case .bottom: return "Push the pointer past the bottom edge of your main display to control your phone."
        }
    }

    @ViewBuilder
    private var controls: some View {
        Section("Phone position") {
            phonePositionPicker
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
            Text("Text is shared when the pointer crosses between your Mac and phone.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var shortcuts: some View {
        Section("Control") {
            VStack(alignment: .leading, spacing: 4) {
                Text("Return pointer to Mac")
                Text("Control + Esc")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Return pointer to Mac: Control + Escape")
        }
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
        Section("Appearance") {
            Picker("Theme", selection: $appearance) {
                Text("System").tag(AppAppearance.system)
                Text("Light").tag(AppAppearance.light)
                Text("Dark").tag(AppAppearance.dark)
            }
            .pickerStyle(.segmented)
        }
        Section("Startup & Dock") {
            Toggle("Launch at login", isOn: $model.launchAtLogin)
            Toggle("Show icon in the Dock", isOn: $model.showDockIcon)
        }
        Section("Updates") {
            if !model.installedVersion.isEmpty {
                LabeledContent("Installed version") { Text(verbatim: model.installedVersion) }
            }
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
            Text(verbatim: keys)
                .font(.system(.callout, design: .rounded, weight: .medium))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
        }
    }

    private var phoneSection: some View {
        let options = model.phoneOptions
        return Section("Phone") {
            if options.isEmpty {
                Label("No phones available", systemImage: "iphone")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(options) { option in
                    Button {
                        if let phone = model.choosePhone(option.id) {
                            detectedPhoneToConfirm = phone
                            confirmingDetectedPhone = true
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "iphone")
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            Text(verbatim: option.name)
                            if let identifier = option.identifier {
                                Text("ID \(identifier)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            if option.isSelected {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                                    .accessibilityHidden(true)
                            }
                        }
                        .frame(minHeight: 28)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(option.isSelected ? .isSelected : [])
                }
            }
        }
    }

    @ViewBuilder
    private var connectionSection: some View {
        if let phone = model.selectedPhone {
            Section("Device connection") {
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
                if phone.isWireless || !model.selectedPhoneHasBothTransports {
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
