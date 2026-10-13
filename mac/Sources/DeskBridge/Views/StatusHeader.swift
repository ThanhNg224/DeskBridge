import SwiftUI

extension AppModel.Phase {
    var color: Color {
        switch self {
        case .paused: .gray
        case .searching: .orange
        case .connected: .green
        case .controlling: .blue
        }
    }
}

/// Top of the Settings window: live status (coloured dot + text), the master switch and the release chord.
struct StatusHeader: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 52, height: 52)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("DeskBridge").font(.title2.weight(.semibold))
                HStack(alignment: .top, spacing: 6) {
                    Circle().fill(model.phase.color).frame(width: 8, height: 8).padding(.top, 5)
                        .accessibilityHidden(true)
                    StatusLine(text: model.status)
                }
                Text("Release control: ⌃⌥⌘⎋").font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
            Toggle("Enabled", isOn: $model.isEnabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityLabel("Enabled")
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 6)
    }
}

/// The status sentence. Always two lines tall, so the layout below does not jump when the text changes length.
struct StatusLine: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(2, reservesSpace: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(text) // full text if a long message is cut
    }
}
