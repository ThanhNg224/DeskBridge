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

    var symbol: String {
        switch self {
        case .paused: "pause.circle.fill"
        case .searching: "magnifyingglass.circle.fill"
        case .connected: "checkmark.circle.fill"
        case .controlling: "cursorarrow.circle.fill"
        }
    }
}

/// Live phone status and control in the Settings window.
struct StatusHeader: View {
    @Bindable var model: AppModel
    let showsMirrorControls: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                PhoneStatus(model: model)
                Toggle("Enable control", isOn: $model.isEnabled)
                    .toggleStyle(.switch)
                    .fixedSize()
            }

            if showsMirrorControls {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) {
                        MirrorControls(model: model)
                        Spacer(minLength: 12)
                        ReleaseShortcut()
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        MirrorControls(model: model)
                        ReleaseShortcut()
                    }
                }
            } else {
                ReleaseShortcut()
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(.background)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// Shared status presentation for the window and menu bar.
struct PhoneStatus: View {
    let model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: model.phase.symbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(model.phase.color)
                .frame(width: 38, height: 38)
                .background(model.phase.color.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                if let phone = model.activePhone ?? model.pendingPhone ?? model.selectedPhone {
                    Text(phone.displayName)
                        .font(.system(.title3, design: .default, weight: .semibold))
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .help(phone.displayName)
                } else {
                    Text("Phone control")
                        .font(.headline)
                }
                if let phone = model.activePhone, model.status == StatusText.connected(phone.connectionLabel)
                    || model.status == StatusText.controlling(phone.connectionLabel)
                {
                    HStack(spacing: 5) {
                        Text(model
                            .phase == .controlling ? LocalizedStringKey("Controlling phone") :
                            LocalizedStringKey("Connected"))
                        Text(verbatim: "·").accessibilityHidden(true)
                        Label(phone.isWireless ? "Wi-Fi" : "USB",
                              systemImage: phone.isWireless ? "wifi" : "cable.connector")
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                } else {
                    StatusLine(text: model.status)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ReleaseShortcut: View {
    var body: some View {
        HStack(spacing: 5) {
            Text("Return pointer to Mac")
                .foregroundStyle(.secondary)
            Text(verbatim: "Control")
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            Text(verbatim: "Esc")
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
        }
        .font(.caption)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Return pointer to Mac: Control + Escape")
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
            .help(text)
    }
}
