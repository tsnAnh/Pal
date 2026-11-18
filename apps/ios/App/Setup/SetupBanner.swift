import PalConnect
import PalDesign
import SwiftUI

struct SetupBanner: View {
    let title: String
    let detail: String
    var actionTitle: String?
    let identifier: String
    var action: () -> Void = {}

    var body: some View {
        HStack(spacing: PalMetrics.screenMargin) {
            VStack(alignment: .leading, spacing: PalMetrics.rowTextSpacing) {
                Text(title)
                    .hermesText(.rowTitle)
                    .fontWeight(.semibold)
                    .foregroundStyle(PalTokens.textPrimary)
                    .accessibilityIdentifier("\(identifier)Title")
                Text(detail)
                    .hermesText(.rowSubtitle)
                    .foregroundStyle(PalTokens.textSecondary)
                    .accessibilityIdentifier("\(identifier)Detail")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let actionTitle {
                SetupButton(title: actionTitle, kind: .primary, identifier: "\(identifier)Action", action: action)
                    .controlSize(.small)
            }
        }
        .padding(PalMetrics.screenMargin)
        .background(PalTokens.selected, in: RoundedRectangle(cornerRadius: PalMetrics.cardRadius, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}

struct SetupResumeBanner: View {
    let offer: SetupResumeOffer
    let action: () -> Void

    var body: some View {
        SetupBanner(
            title: offer.title, detail: offer.detail, actionTitle: String(localized: "Continue"), identifier: "setupResumeBanner", action: action
        )
    }
}
