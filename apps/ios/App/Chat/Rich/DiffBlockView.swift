import PalChat
import PalDesign
import SwiftUI

struct DiffBlockView: View {
    let source: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let model = RichRendering.diff(source)
        if model.lines.isEmpty {
            PlainFallbackView(source: source, note: String(localized: "Showing plain text"))
        } else {
            let palette = RichPalette(colorScheme)
            RichCardFrame(title: String(localized: "Diff"), copyText: source, identifier: "diffBlock") {
                Text("+\(model.added) \u{2212}\(model.removed)")
                    .hermesText(.chip)
                    .monospacedDigit()
                    .foregroundStyle(PalTokens.textSecondary)
                    .accessibilityHidden(true)
            } content: {
                ExpandableBlock(lineCount: model.lines.count) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(model.lines.enumerated()), id: \.offset) { _, line in
                            DiffLineRow(line: line, palette: palette)
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .textSelection(.enabled)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(accessibilityText(model)))
                }
            }
        }
    }

    private func accessibilityText(_ model: DiffModel) -> String {
        String(localized: "\(model.added) additions, \(model.removed) deletions") + ". " + source
    }
}

private struct DiffLineRow: View {
    let line: DiffLine
    let palette: RichPalette

    var body: some View {
        Text(line.text.isEmpty ? " " : line.text)
            .hermesText(.chatCode)
            .font(RichCode.font)
            .fontWeight(line.kind == .fileHeader ? .bold : nil)
            .foregroundStyle(foreground)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background)
    }

    private var foreground: Color {
        switch line.kind {
        case .hunk: PalTokens.textTertiary
        case .meta: PalTokens.textSecondary
        case .added, .removed, .context, .fileHeader: PalTokens.textPrimary
        }
    }

    private var background: Color {
        switch line.kind {
        case .added: palette.addedTint
        case .removed: palette.removedTint
        case .hunk: palette.hunkTint
        case .context, .fileHeader, .meta: .clear
        }
    }
}

struct PlainFallbackView: View {
    let source: String
    let note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            CodeBlockView(text: source)
            Text(note)
                .hermesText(.chip)
                .foregroundStyle(PalTokens.textTertiary)
        }
    }
}
