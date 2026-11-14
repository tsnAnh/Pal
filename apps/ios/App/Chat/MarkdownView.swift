import PalChat
import PalDesign
import SwiftUI

struct MarkdownView: View {
    let document: MarkdownDocument
    let highlight: String
    let isCurrentMatch: Bool
    var isStreaming: Bool = false

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(document.layoutItems) { item in
                switch item {
                case .block(let block):
                    blockView(block)
                case .quote(let blocks):
                    quoteView(blocks)
                }
            }
        }
    }

    private func blockView(_ block: MarkdownBlock) -> some View {
        MarkdownBlockView(block: block, highlight: highlight, isCurrentMatch: isCurrentMatch, isStreaming: isStreaming)
    }

    private func quoteView(_ blocks: [MarkdownBlock]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks) { block in
                blockView(block)
            }
        }
        .padding(.leading, 13)
        .overlay(alignment: .leading) {
            Rectangle().fill(Color(theme.palette.textTertiary)).frame(width: 3)
        }
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let highlight: String
    let isCurrentMatch: Bool
    let isStreaming: Bool

    @Environment(\.hermesTheme) private var theme
    @ScaledMetric(relativeTo: .body) private var indentStep: CGFloat = 25.7

    var body: some View {
        switch block.kind {
        case .paragraph:
            if block.isComplete, let link = block.standaloneLink, MediaLink.isInlinePlayableVideo(link) {
                VideoBlockView(url: link)
            } else if block.isComplete, let link = block.standaloneLink, let descriptor = EmbedDetector.detect(link) {
                EmbedCardView(descriptor: descriptor)
            } else {
                listRow { InlineText(text: block.text, highlight: highlight, isCurrentMatch: isCurrentMatch) }
            }
        case .heading(let level):
            InlineText(text: block.text, highlight: highlight, isCurrentMatch: isCurrentMatch, style: level <= 2 ? .chatStatus : .chatBody, weight: .bold)
        case .code, .math:
            RichBlockView(block: block, isStreaming: isStreaming)
        case .table(let table):
            listRow { MarkdownTableView(table: table, highlight: highlight, isCurrentMatch: isCurrentMatch) }
        case .thematicBreak:
            Rectangle().fill(Color(theme.palette.separator)).frame(height: 1).padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func listRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if block.lists.isEmpty {
            content()
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Color.clear.frame(width: indentStep * CGFloat(block.lists.count - 1), height: 1)
                marker.frame(width: indentStep, alignment: .leading)
                content()
            }
        }
    }

    @ViewBuilder
    private var marker: some View {
        if block.startsListItem, let list = block.lists.last {
            Text(list.style == .ordered ? "\(list.ordinal)." : "•")
                .hermesText(.chatBody)
                .foregroundStyle(Color(theme.palette.textSecondary))
        } else {
            Color.clear.frame(width: 1, height: 1)
        }
    }
}

struct CodeBlockView: View {
    let text: String

    @Environment(\.hermesTheme) private var theme

    private var codeFont: Font { RichCode.font }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(text)
                .hermesText(.chatCode)
                .font(codeFont)
                .foregroundStyle(PalTokens.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: true)
                .padding(10)
        }
        .background(PalTokens.textPrimary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityIdentifier("codeBlock")
    }
}

struct InlineText: View {
    let text: AttributedString
    let highlight: String
    let isCurrentMatch: Bool
    var style: PalTextStyle = .chatBody
    var weight: Font.Weight?
    var foreground: Color?

    @Environment(\.hermesTheme) private var theme
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 17

    var body: some View {
        composed
            .hermesText(style)
            .fontWeight(weight)
            .lineSpacing(3.2)
            .foregroundStyle(foreground ?? defaultInk)
            .tint(foreground ?? defaultInk)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var defaultInk: Color { PalTokens.textPrimary }

    private var composed: Text {
        let fill = isCurrentMatch ? Color(theme.palette.primaryBadge) : Color.yellow.opacity(0.35)
        let highlighted = InlineTextComposer.highlight(text, query: highlight, fill: fill, ink: isCurrentMatch ? .black : nil)
        return InlineTextComposer.compose(highlighted) { link in
            if let icon = FaviconCache.shared.image(for: link, pointSize: iconSize) {
                return Text(Image(platformImage: icon))
            }
            return Text(Image(systemName: "globe")).foregroundStyle(Color(theme.palette.textSecondary))
        }
    }
}
