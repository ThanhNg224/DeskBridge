import SwiftUI

/// The popover of the menu bar item.
struct MenuBarView: View {
    @Bindable var model: AppModel
    let openSetup: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PhoneStatus(model: model)

            Toggle("Enable control", isOn: $model.isEnabled)
                .toggleStyle(.switch)

            if !model.setup.isComplete {
                Button("Finish setup…", action: openSetup)
            }

            MirrorControls(model: model, expandsPrimaryAction: true)
            ReleaseShortcut()

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
