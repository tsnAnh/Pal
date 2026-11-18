import PalConnect
import PalDesign
import SwiftUI

struct StepFlowHeader: View {
    let title: String
    let close: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack {
            Text(title)
                .hermesText(.sheetTitle)
                .foregroundStyle(PalTokens.textPrimary)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("stepFlowTitle")
            Spacer()
            Button(role: .close, action: close)
                .buttonStyle(.glass(PalGlass.style(interactive: true, colorScheme: colorScheme)))
                .accessibilityIdentifier("stepFlowClose")
        }
        .padding(.horizontal, PalMetrics.screenMargin)
        .padding(.vertical, PalMetrics.captionToCardGap)
    }
}

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
