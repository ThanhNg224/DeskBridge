import DeskBridgeCore
import SwiftUI

struct PhonePlacementView: View {
    @Binding var edge: ScreenEdge

    var body: some View {
        VStack(spacing: 12) {
            diagram
                .frame(maxWidth: .infinity)
                .frame(height: 132)
                .background {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(LinearGradient(
                            colors: [Color.accentColor.opacity(0.11), Color.accentColor.opacity(0.025)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                }
                .accessibilityHidden(true)

            Picker("Android is on the", selection: $edge) {
                Text("Left").tag(ScreenEdge.left)
                Text("Right").tag(ScreenEdge.right)
                Text("Top").tag(ScreenEdge.top)
                Text("Bottom").tag(ScreenEdge.bottom)
            }
            .pickerStyle(.segmented)
        }
    }

    private var diagram: some View {
        ZStack {
            // Center the pair as one arrangement, including when the phone is above or below the Mac.
            VStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.06))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.primary.opacity(0.55), lineWidth: 2)
                    }
                    .overlay {
                        Image(systemName: "cursorarrow")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    .overlay { selectedEdge }
                    .frame(width: 90, height: 52)
                Rectangle()
                    .fill(Color.primary.opacity(0.55))
                    .frame(width: 4, height: 5)
                Capsule()
                    .fill(Color.primary.opacity(0.55))
                    .frame(width: 26, height: 3)
            }

            phone
                .offset(phoneOffset)
        }
        .offset(x: -phoneOffset.width * 0.28, y: -phoneOffset.height * 0.42)
    }

    private var phone: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color.accentColor.opacity(0.12))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.accentColor, lineWidth: 2.5)
            }
            .overlay(alignment: .top) {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 8, height: 2)
                    .padding(.top, 5)
            }
            .frame(width: 21, height: 37)
    }

    private var selectedEdge: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color.accentColor)
            .frame(width: edge == .left || edge == .right ? 4 : 32,
                   height: edge == .left || edge == .right ? 32 : 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: edgeAlignment)
    }

    private var edgeAlignment: Alignment {
        switch edge {
        case .left: .leading
        case .right: .trailing
        case .top: .top
        case .bottom: .bottom
        }
    }

    private var phoneOffset: CGSize {
        switch edge {
        case .left: CGSize(width: -68, height: -3)
        case .right: CGSize(width: 68, height: -3)
        case .top: CGSize(width: 0, height: -55)
        case .bottom: CGSize(width: 0, height: 56)
        }
    }
}
