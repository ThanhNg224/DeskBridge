import DeskBridgeCore
import SwiftUI

/// Live checklist of what DeskBridge needs. Shown at the top of Settings until everything is ready.
struct SetupChecklist: View {
    let setup: SetupState

    private static let adbInstallCommand = "brew install --cask android-platform-tools"

    var body: some View {
        Section("Setup") {
            row(ok: setup.accessibility, title: "Accessibility access",
                hint: "Needed to read the mouse and keyboard.")
            {
                Button("Open Settings") { Permissions.openSettings(.accessibility) }
                Button("Input Monitoring") { Permissions.openSettings(.inputMonitoring) }
            }
            row(ok: setup.adbFound, title: "Android tools (adb)", hint: "Install them with Homebrew:") {
                Button("Copy command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Self.adbInstallCommand, forType: .string)
                }
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
            row(ok: false, title: "No phone found", hint: "Connect via USB cable or Wi-Fi (wireless debugging).") {
                EmptyView()
            }
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
