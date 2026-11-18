import PalConnect
import PalDesign
import SwiftUI

struct StepIntroCard: View {
    let youDo: String
    let palDoes: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row(title: String(localized: "You do"), text: youDo, identifier: "stepFlowIntroYouDo")
            PalHairline()
            row(title: String(localized: "Pal does"), text: palDoes, identifier: "stepFlowIntroPalDoes")
        }
        .background(PalTokens.control, in: RoundedRectangle(cornerRadius: PalMetrics.cardRadius, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("stepFlowIntro")
    }

    private func row(title: String, text: String, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: PalMetrics.rowTextSpacing) {
            Text(title)
                .hermesText(.rowSubtitle)
                .fontWeight(.semibold)
                .foregroundStyle(PalTokens.textTertiary)
            Text(text)
                .hermesText(.rowTitle)
                .foregroundStyle(PalTokens.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(PalMetrics.screenMargin)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }
}

struct StepFlowLinks: View {
    let links: [SetupLink]

    var body: some View {
        VStack(spacing: PalMetrics.captionToCardGap) {
            ForEach(Array(links.enumerated()), id: \.offset) { offset, link in
                SetupButton(title: link.label, fillsWidth: true, identifier: "stepFlowLink-\(offset)") { ExternalLink.open(link.url) }
            }
        }
    }
}
