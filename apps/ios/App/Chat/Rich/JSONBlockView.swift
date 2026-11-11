import PalChat
import PalDesign
import SwiftUI

struct JSONBlockView: View {
    let source: String

    @State private var collapsed: Bool
    @Environment(\.colorScheme) private var colorScheme

    init(source: String) {
        self.source = source
        let lines = RichRendering.json(source).map { RichCode.lineCount($0.pretty) } ?? 0
        _collapsed = State(initialValue: lines > RichCode.collapseLines)
    }

    var body: some View {
        if let presentation = RichRendering.json(source) {
            let collapsible = RichCode.lineCount(presentation.pretty) > RichCode.collapseLines
            RichCardFrame(title: "JSON", copyText: presentation.pretty, identifier: "jsonBlock") {
                HStack(spacing: 4) {
                    Text(presentation.summary)
                        .hermesText(.chip)
                        .foregroundStyle(PalTokens.textTertiary)
                        .lineLimit(1)
                    if collapsible {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { collapsed.toggle() }
                        } label: {
                            Image(systemName: collapsed ? "chevron.down" : "chevron.up")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(PalTokens.textSecondary)
                                .frame(minWidth: 28, minHeight: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(collapsed ? LocalizedStringKey("Expand") : LocalizedStringKey("Collapse")))
                        .accessibilityIdentifier("jsonToggle")
                    }
                }
            } content: {
                if !collapsed {
                    ExpandableBlock(lineCount: RichCode.lineCount(presentation.pretty)) {
                        Text(RichRendering.code(presentation.pretty, language: "json", scheme: colorScheme))
                            .hermesText(.chatCode)
                            .font(RichCode.font)
                            .foregroundStyle(PalTokens.textPrimary)
                            .textSelection(.enabled)
                    }
                }
            }
        } else {
            PlainFallbackView(source: source, note: String(localized: "Showing plain text"))
        }
    }
}
