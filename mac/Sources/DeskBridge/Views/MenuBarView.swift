import SwiftUI

/// The popover of the menu bar item: status, the master switch and the way to Settings. Nothing else.
struct MenuBarView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                    .padding(.top, 6)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("DeskBridge").font(.headline)
                    Text(model.status)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("Enabled", isOn: $model.isEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .accessibilityLabel("Enabled")
            }

            if !model.setup.isComplete {
                Button("Finish setup…") { SettingsWindow.open() }
            }

            Divider()

            HStack {
                Button("Settings…") { SettingsWindow.open() }
                    .keyboardShortcut(",")
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private var statusColor: Color {
        switch model.phase {
        case .paused: .gray
        case .searching: .orange
        case .connected: .green
        case .controlling: .blue
        }
    }
}
