import DeskBridgeCore
import SwiftUI
import UniformTypeIdentifiers

/// Live checklist of what DeskBridge needs. Shown in Connection until everything is ready.
struct SetupChecklist: View {
    let model: AppModel

    private var setup: SetupState {
        model.setup
    }

    var body: some View {
        Section("Set up DeskBridge") {
            if !setup.accessibility {
                task("Allow Accessibility access") {
                    Text(
                        "Turn on DeskBridge in Accessibility so it can use your mouse and keyboard to control the phone."
                    )
                    Button("Open Settings for Accessibility") {
                        Permissions.openSettings(.accessibility)
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else if !setup.adbFound || model.installingADB {
                task("Install Android tools (adb)") {
                    Text("Download Platform Tools for Mac from Google, then select the ZIP here.")
                    Link(
                        "Download from Google",
                        destination: URL(string: "https://developer.android.com/tools/releases/platform-tools")!
                    )
                    Button("Select ZIP…") { selectZIP() }
                        .disabled(model.installingADB)
                    if model.installingADB {
                        ProgressView().controlSize(.small)
                    }
                    if let error = model.adbInstallError {
                        Text(verbatim: error).font(.caption).foregroundStyle(.red)
                    }
                }
            } else if setup.needsInputMonitoringHelp {
                task("Check Input Monitoring") {
                    Text(
                        "Accessibility is on, but DeskBridge could not use your mouse and keyboard. Check DeskBridge in Input Monitoring, then try again."
                    )
                    Button("Open Input Monitoring") {
                        Permissions.openSettings(.inputMonitoring)
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Try again") { model.retryConnection() }
                        .disabled(!model.isEnabled || model.isOperatingWireless)
                }
            } else {
                deviceTask
            }
        }
    }

    @ViewBuilder
    private var deviceTask: some View {
        switch setup.device {
        case .none:
            task("Connect your phone by USB") {
                Text("Tap Build number seven times in About phone. On Samsung, look in Software information.")
                Text(
                    "Turn on USB debugging in Developer options. Connect a USB data cable, unlock your phone, then tap Allow."
                )
                Link(
                    "Android developer-options guide",
                    destination: URL(string: "https://developer.android.com/studio/debug/dev-options")!
                )
            }
        case .notAuthorized:
            task("Allow USB debugging on your phone") {
                Text("Unlock your phone and tap Allow on the USB debugging prompt.")
            }
        case .choose:
            task("Choose a phone") {
                Text("Select the phone you want to control below.")
            }
        case let .waiting(name):
            task("Waiting for \(name)") {
                Text("Reconnect the selected device or choose another one.")
            }
        case .ready:
            EmptyView()
        }
    }

    private func selectZIP() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        if panel.runModal() == .OK, let url = panel.url {
            model.installADB(from: url)
        }
    }

    private func task(
        _ title: LocalizedStringKey,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
            VStack(alignment: .leading, spacing: 6, content: content)
                .font(.caption)
                .controlSize(.small)
        }
        .padding(.vertical, 4)
    }
}
