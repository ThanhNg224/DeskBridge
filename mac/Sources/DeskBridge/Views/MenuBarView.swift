import SwiftUI

/// The popover of the menu bar item: status, the master switch and the way to Settings. Nothing else.
struct MenuBarView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(model.phase.color)
                    .frame(width: 8, height: 8)
                    .padding(.top, 6)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("DeskBridge").font(.headline)
                    StatusLine(text: model.status)
                }
                Spacer(minLength: 8)
                Toggle("Enabled", isOn: $model.isEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .accessibilityLabel("Enabled")
            }

            if !model.setup.isComplete {
                Button("Finish setup…") { AppWindow.show() }
            }

            Divider()

            HStack {
                Button("Settings…") { AppWindow.show() }
                    .keyboardShortcut(",")
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(16)
        .frame(width: 340)
        .modifier(RegisterWindowOpener()) // so "Settings…" works even if the window was never shown
    }
}
