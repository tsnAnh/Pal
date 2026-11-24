import PalChat
import PalDesign
import SwiftUI

struct ClarifySettledCard: View {
    let settled: ClarifySettled

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: ClarifySettledMetrics.entrySpacing) {
            ForEach(Array(settled.entries.enumerated()), id: \.offset) { _, entry in
                VStack(alignment: .leading, spacing: ClarifySettledMetrics.titleToRows) {
                    Text(entry.question)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(Color(theme.palette.textPrimary))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: ClarifySettledMetrics.rowSpacing) {
                        if entry.isSkipped {
                            Text("Skipped")
                                .font(.body)
                                .foregroundStyle(Color(theme.palette.textSecondary))
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            ForEach(Array(entry.chosen.enumerated()), id: \.offset) { _, pick in
                                chosenRow(pick)
                            }
                        }
                    }
                }
            }
        }
        .padding(ClarifySettledMetrics.surfacePadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .palClearGlass(RoundedRectangle(cornerRadius: ChatMetrics.bubbleRadius, style: .continuous), interactive: false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: Self.spoken(settled)))
        .accessibilityIdentifier(settled.isSingle ? "clarifyAnswered" : "clarifyAnsweredForm")
    }

    private func chosenRow(_ pick: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: ClarifySettledMetrics.markGap) {
            PalIcon("checkmark", ink: .destructive)
                .font(.body.weight(.semibold))
                .frame(width: ClarifySettledMetrics.markWidth)
            Text(verbatim: pick)
                .font(.body)
                .foregroundStyle(Color(theme.palette.textPrimary))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    static func spoken(_ settled: ClarifySettled) -> String {
        settled.entries.map { entry in
            "\(entry.question): \(entry.isSkipped ? String(localized: "Skipped") : entry.chosen.joined(separator: ", "))"
        }.joined(separator: ". ")
    }
}
