import PalChat
import PalDesign
import SwiftUI

struct MarkdownView: View {
    private enum Content {
        case items([MarkdownLayoutItem])
        #if os(macOS)
        case runs([MarkdownRun])
        #endif
    }

    private let content: Content
    private let perBlockSelection: Bool
    let highlight: String
    let isCurrentMatch: Bool
    var isStreaming: Bool = false

    init(parsed: ParsedMarkdown, highlight: String, isCurrentMatch: Bool, isStreaming: Bool = false) {
        content = .items(parsed.document.layoutItems)
        perBlockSelection = false
        self.highlight = highlight
        self.isCurrentMatch = isCurrentMatch
        self.isStreaming = isStreaming
    }

    init(segment: TextSegment, wholeBubbleSelection: Bool, highlight: String, isCurrentMatch: Bool, isStreaming: Bool = false) {
        #if os(macOS)
        content = wholeBubbleSelection ? .runs(segment.runs) : .items(segment.items)
        #else
        content = .items(segment.items)
        #endif
        perBlockSelection = !wholeBubbleSelection
        self.highlight = highlight
        self.isCurrentMatch = isCurrentMatch
        self.isStreaming = isStreaming
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ChatMetrics.blockSpacing) {
            switch content {
            case .items(let items):
                ForEach(items) { item in
                    MarkdownItemView(item: item, highlight: highlight, isCurrentMatch: isCurrentMatch, isStreaming: isStreaming)
                        .equatable()
                }
            #if os(macOS)
            case .runs(let runs):
                ForEach(runs) { run in
                    MarkdownRunView(run: run, highlight: highlight, isCurrentMatch: isCurrentMatch, isStreaming: isStreaming)
                        .equatable()
                }
            #endif
            }
        }
        .modifier(PerBlockSelection(isOn: perBlockSelection))
    }

}

struct MarkdownItemView: View, Equatable {
    let item: MarkdownLayoutItem
    var highlight = ""
    var isCurrentMatch = false
    var isStreaming = false

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item == rhs.item && lhs.highlight == rhs.highlight && lhs.isCurrentMatch == rhs.isCurrentMatch && lhs.isStreaming == rhs.isStreaming
    }

    var body: some View {
        switch item {
        case .block(let block):
            MarkdownBlockView(block: block, highlight: highlight, isCurrentMatch: isCurrentMatch, isStreaming: isStreaming)
        case .quote(let blocks):
            MarkdownQuote(content: ForEach(blocks) { block in
                MarkdownBlockView(block: block, highlight: highlight, isCurrentMatch: isCurrentMatch, isStreaming: isStreaming)
                    .equatable()
            })
        }
    }
}

private struct PerBlockSelection: ViewModifier {
    let isOn: Bool

    func body(content: Content) -> some View {
        #if os(macOS)
        if isOn { content.textSelection(.enabled) } else { content }
        #else
        content
        #endif
    }
}

struct MarkdownQuote<Inner: View>: View {
    let content: Inner

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: ChatMetrics.blockSpacing) { content }
            .padding(.leading, 13)
            .overlay(alignment: .leading) {
                Rectangle().fill(Color(theme.palette.textTertiary)).frame(width: 3)
            }
    }
}

#if os(macOS)
private struct MarkdownRunView: View, Equatable {
    let run: MarkdownRun
    let highlight: String
    let isCurrentMatch: Bool
    let isStreaming: Bool

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.run == rhs.run && lhs.highlight == rhs.highlight && lhs.isCurrentMatch == rhs.isCurrentMatch && lhs.isStreaming == rhs.isStreaming
    }

    var body: some View {
        switch run {
        case .text(_, let text):
            SelectableMarkdownText(text: text, highlight: highlight, isCurrentMatch: isCurrentMatch)
        case .block(let block):
            MarkdownBlockView(block: block, highlight: highlight, isCurrentMatch: isCurrentMatch, isStreaming: isStreaming)
        case .quote(_, let runs):
            MarkdownQuote(content: ForEach(runs) { inner in
                MarkdownRunView(run: inner, highlight: highlight, isCurrentMatch: isCurrentMatch, isStreaming: isStreaming)
                    .equatable()
            })
        }
    }
}
#endif

struct MarkdownBlockView: View, Equatable {
    let block: MarkdownBlock
    let highlight: String
    let isCurrentMatch: Bool
    let isStreaming: Bool

    @Environment(\.hermesTheme) private var theme
    @ScaledMetric(relativeTo: .body) private var indentStep: CGFloat = 25.7

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.block == rhs.block && lhs.highlight == rhs.highlight && lhs.isCurrentMatch == rhs.isCurrentMatch && lhs.isStreaming == rhs.isStreaming
    }

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
                .chatText(.chatBody)
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
    @Environment(\.chatInk) private var chatInk
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 17

    var body: some View {
        composed
            .chatText(style)
            .fontWeight(weight)
            .foregroundStyle(foreground ?? defaultInk)
            .tint(foreground ?? defaultInk)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var defaultInk: Color { PalTokens.textPrimary }

    private var composed: Text {
        let mark = FindMark(ink: chatInk, surfaceText: foreground, isCurrent: isCurrentMatch)
        let highlighted = InlineTextComposer.highlight(text, query: highlight, fill: mark.fill, ink: mark.text)
        return InlineTextComposer.compose(highlighted) { link in
            if let icon = FaviconCache.shared.image(for: link, pointSize: iconSize) {
                return Text(Image(platformImage: icon))
            }
            return Text(Image(systemName: "globe")).foregroundStyle(Color(theme.palette.textSecondary))
        }
    }
}
