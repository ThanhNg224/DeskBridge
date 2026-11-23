import SwiftUI

struct MirrorControls: View {
    let model: AppModel
    var expandsPrimaryAction = false

    var body: some View {
        switch model.mirrorPhase {
        case .idle, .disconnected:
            VStack(alignment: .leading, spacing: 8) {
                primaryAction("Open phone screen", enabled: model.canOpenMirror)
                if !model.isEnabled {
                    hint("Enable DeskBridge to open the phone screen.")
                } else if model.isOperatingWireless || model.installingADB {
                    hint("Wait for the connection to finish before opening the phone screen.")
                } else if !model.canOpenMirror {
                    hint("Connect your phone to open its screen.")
                }
            }
        case .opening:
            HStack(spacing: 8) {
                primaryAction("Opening phone screen…", enabled: false, showsProgress: true)
                Button("Cancel") { model.closeMirror() }
            }
        case .open, .focusFailed:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    primaryAction("Bring phone screen forward")
                    Button("Close") { model.closeMirror() }
                        .accessibilityLabel("Close phone screen")
                }
                if model.mirrorPhase == .focusFailed {
                    hint("Open scrcpy from the Dock, or close the phone screen and open it again.")
                }
                hint("Moving across the screen edge is paused.")
            }
        case .closing:
            primaryAction("Closing phone screen…", enabled: false, showsProgress: true)
        case .notInstalled:
            hint("Reinstall DeskBridge to restore the phone screen files.")
        case .failed:
            VStack(alignment: .leading, spacing: 8) {
                primaryAction("Try again", enabled: model.canOpenMirror)
                hint("Could not show the phone screen. Check the phone connection and try again.")
            }
        }
    }

    private func primaryAction(
        _ title: LocalizedStringKey, enabled: Bool = true, showsProgress: Bool = false
    ) -> some View {
        Button(action: model.openMirror) {
            HStack(spacing: 6) {
                if showsProgress {
                    ProgressView().controlSize(.small).accessibilityHidden(true)
                } else {
                    Image(systemName: "laptopcomputer.and.iphone").accessibilityHidden(true)
                }
                Text(title)
            }
            .frame(maxWidth: expandsPrimaryAction ? .infinity : nil)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!enabled)
    }

    private func hint(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
