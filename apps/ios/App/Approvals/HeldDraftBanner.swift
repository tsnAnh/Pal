import PalChat
import PalDesign
import SwiftUI

struct HeldDraftBanner: View {
    let count: Int
    let review: () -> Void

    @Environment(\.hermesTheme) private var theme

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 16, style: .continuous) }

    private var message: String {
        count == 1 ? String(localized: "1 message waiting for you.") : String(localized: "\(count) messages waiting for you.")
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Color(theme.palette.textPrimary))
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("heldDraftBannerTitle")
            Button("Review", action: review)
                .glassButtonStyle()
                .accessibilityIdentifier("heldDraftBannerReview")
        }
        .padding(12)
        .palClearGlass(shape, interactive: false)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("heldDraftBanner")
    }
}
