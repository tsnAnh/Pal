import HermesChat
import HermesDesign
import SwiftUI

struct MarkdownView: View {
    let document: MarkdownDocument
    let highlight: String
    let isCurrentMatch: Bool

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(document.blocks) { block in
                MarkdownBlockView(block: block, highlight: highlight, isCurrentMatch: isCurrentMatch)
            }
        }
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let highlight: String
    let isCurrentMatch: Bool

    @Environment(\.hermesTheme) private var theme
    @ScaledMetric(relativeTo: .body) private var indentStep: CGFloat = 25.7

    var body: some View {
        switch block.kind {
        case .paragraph:
            listRow { InlineText(text: block.text, highlight: highlight, isCurrentMatch: isCurrentMatch) }
        case .heading(let level):
            InlineText(text: block.text, highlight: highlight, isCurrentMatch: isCurrentMatch, style: level <= 2 ? .chatStatus : .chatBody, weight: .bold)
        case .code:
            CodeBlockView(text: String(block.text.characters))
        case .thematicBreak:
            Rectangle().fill(Color(theme.palette.separator)).frame(height: 1).padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func listRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if block.lists.isEmpty && !block.isQuoted {
            content()
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                if block.isQuoted {
                    Rectangle().fill(Color(theme.palette.textTertiary)).frame(width: 3).padding(.trailing, 10)
                }
                if !block.lists.isEmpty {
                    Color.clear.frame(width: indentStep * CGFloat(block.lists.count - 1), height: 1)
                    marker.frame(width: indentStep, alignment: .leading)
                }
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

private struct CodeBlockView: View {
    let text: String

    @Environment(\.hermesTheme) private var theme

    private var codeFont: Font {
        #if os(macOS)
        .system(size: 12, design: .monospaced)
        #else
        .system(.footnote, design: .monospaced)
        #endif
    }

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
    var style: HermesTextStyle = .chatBody
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
        let highlighted = Self.applyHighlight(to: text, query: highlight, current: isCurrentMatch, theme: theme)
        var result = Text("")
        for run in highlighted.runs {
            let slice = AttributedString(highlighted[run.range])
            if let link = run.link {
                let icon = FaviconCache.shared.image(for: link, pointSize: iconSize)
                let iconText = icon.map { Text(Image(platformImage: $0)) } ?? Text(Image(systemName: "globe")).foregroundStyle(Color(theme.palette.textSecondary))
                result = Text("\(result)\(iconText)\(Text(" "))\(Text(slice).underline())")
            } else {
                result = Text("\(result)\(Text(slice))")
            }
        }
        return result
    }

    static func applyHighlight(to text: AttributedString, query: String, current: Bool, theme: HermesTheme) -> AttributedString {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return text }
        var result = text
        let plain = String(text.characters)
        var searchRange = plain.startIndex..<plain.endIndex
        let fill = current ? Color(theme.palette.primaryBadge) : Color.yellow.opacity(0.35)
        while let found = plain.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange) {
            let lower = result.index(result.startIndex, offsetByCharacters: plain.distance(from: plain.startIndex, to: found.lowerBound))
            let upper = result.index(result.startIndex, offsetByCharacters: plain.distance(from: plain.startIndex, to: found.upperBound))
            result[lower..<upper].backgroundColor = fill
            if current { result[lower..<upper].foregroundColor = .black }
            searchRange = found.upperBound..<plain.endIndex
        }
        return result
    }
}
