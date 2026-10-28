import DeskBridgeCore
import SwiftUI
import UniformTypeIdentifiers

/// Live checklist of what DeskBridge needs. Shown at the top of Settings until everything is ready.
struct SetupChecklist: View {
    let model: AppModel
    private var setup: SetupState {
        model.setup
    }

    var body: some View {
        Section("Setup") {
            row(ok: setup.accessibility, title: "Accessibility access",
                hint: "Needed to read the mouse and keyboard.")
            {
                Button("Open Settings") { Permissions.openSettings(.accessibility) }
                Button("Input Monitoring") { Permissions.openSettings(.inputMonitoring) }
            }
            row(ok: setup.adbFound, title: "Android tools (adb)",
                hint: "Download Platform Tools for Mac from Google, then select the ZIP.")
            {
                Link(
                    "Download from Google",
                    destination: URL(string: "https://developer.android.com/tools/releases/platform-tools")!
                )
                Button("Select ZIP…") { selectZIP() }.disabled(model.installingADB)
                if model.installingADB {
                    ProgressView().controlSize(.small)
                }
            }
            if let error = model.adbInstallError {
                Text(verbatim: error).font(.caption).foregroundStyle(.red)
            }
            deviceRow
        }
    }

    @ViewBuilder
    private var deviceRow: some View {
        switch setup.device {
        case let .ready(name):
            row(ok: true, title: "Phone: \(name)", hint: "") { EmptyView() }
        case let .notAuthorized(state):
            row(ok: false, title: "Phone not authorized (\(state))", hint: "Unlock the phone and tap Allow.") {
                EmptyView()
            }
        case let .choose(count):
            row(ok: false, title: "\(count) phones found", hint: "Pick one in the Phone section below.") { EmptyView() }
        case let .waiting(name):
            row(ok: false, title: "Waiting for \(name)", hint: "Reconnect the selected device or choose another one.") {
                EmptyView()
            }
        case .none:
            row(
                ok: false,
                title: "No phone found",
                hint: "On your phone, tap Build number seven times in About phone. Enable USB debugging in Developer options, connect with USB, then tap Allow."
            ) {
                EmptyView()
            }
        }
    }

    private func selectZIP() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            model.installADB(from: url)
        }
    }

    private func row(
        ok: Bool, title: LocalizedStringKey, hint: LocalizedStringKey, @ViewBuilder actions: () -> some View
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? Color.green : Color.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                if !ok {
                    Text(hint).font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 8) { actions() }.controlSize(.small)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
