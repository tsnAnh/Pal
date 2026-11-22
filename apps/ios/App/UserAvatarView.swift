import PalDesign
import PalRoster
import SwiftUI

struct UserAvatarView: View {
    let initial: String
    let photo: CGImage?
    let link: GatewayLink

    @Environment(\.hermesTheme) private var theme

    private var presenceColor: Color {
        switch link {
        case .connected: Color(theme.palette.accentBlue)
        case .reconnecting: .orange
        case .offline: Color(theme.palette.textTertiary)
        }
    }

    private var presenceLabel: LocalizedStringKey {
        switch link {
        case .connected: "Connected"
        case .reconnecting: "Reconnecting"
        case .offline: "Offline"
        }
    }

    var body: some View {
        face
            .overlay(alignment: .bottomTrailing) {
                Circle()
                    .fill(presenceColor)
                    .frame(width: 8, height: 8)
                    .offset(x: photo == nil ? 6 : 2, y: photo == nil ? 4 : 2)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityValue(Text(presenceLabel))
    }

    @ViewBuilder
    private var face: some View {
        if let photo {
            Image(decorative: photo, scale: 1)
                .resizable()
                .scaledToFill()
                .frame(width: 34, height: 34)
                .clipShape(Circle())
        } else {
            Text(initial)
                .font(.headline)
                .foregroundStyle(Color(theme.palette.textPrimary))
        }
    }
}
