import PalDesign
import PalKanban
import SwiftUI

struct KanbanBodyView: View {
    static let cardScheme = "palkanban-card"

    let blocks: [KanbanBodyBlock]
    var refs: [String: String] = [:]
    let openCard: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, PalMetrics.rowInset)
        .padding(.vertical, PalMetrics.rowVerticalPadding)
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == Self.cardScheme, !url.path.isEmpty else { return .systemAction }
            openCard(url.path)
            return .handled
        })
    }

    @ViewBuilder
    private func view(for block: KanbanBodyBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(Self.inline(text, refs: refs))
                .font(level <= 2 ? .headline : .subheadline.weight(.semibold))
                .foregroundStyle(PalTokens.textPrimary)
        case .paragraph(let text):
            Text(Self.inline(text, refs: refs))
                .hermesText(.chatBody)
                .foregroundStyle(PalTokens.textPrimary)
        case .bullets(let items):
            list(items) { _ in "•" }
        case .numbered(let items):
            list(items) { "\($0 + 1)." }
        case .code(let code):
            ScrollView(.horizontal) {
                Text(code)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(PalTokens.textPrimary)
                    .padding(10)
            }
            .background(PalTokens.control, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func list(_ items: [String], marker: @escaping (Int) -> String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(marker(index)).foregroundStyle(PalTokens.textSecondary)
                    Text(Self.inline(item, refs: refs)).foregroundStyle(PalTokens.textPrimary)
                }
                .hermesText(.chatBody)
            }
        }
    }

    static func inline(_ text: String, refs: [String: String] = [:]) -> AttributedString {
        var result = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        let plain = String(result.characters)
        link(refs: refs, in: plain, of: &result)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return result }
        for match in detector.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)) {
            guard let url = match.url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  let range = Range(match.range, in: plain),
                  let start = AttributedString.Index(range.lowerBound, within: result),
                  let end = AttributedString.Index(range.upperBound, within: result),
                  result[start..<end].link == nil
            else { continue }
            result[start..<end].link = url
        }
        return result
    }

    private static func link(refs: [String: String], in plain: String, of result: inout AttributedString) {
        guard !refs.isEmpty else { return }
        for range in KanbanRef.ranges(in: plain) {
            guard let taskID = refs[KanbanRef.normalized(String(plain[range]))],
                  let url = cardURL(taskID),
                  let start = AttributedString.Index(range.lowerBound, within: result),
                  let end = AttributedString.Index(range.upperBound, within: result),
                  result[start..<end].link == nil
            else { continue }
            result[start..<end].link = url
            result[start..<end].underlineStyle = .single
        }
    }

    private static func cardURL(_ taskID: String) -> URL? {
        var components = URLComponents()
        components.scheme = cardScheme
        components.path = taskID
        return components.url
    }
}

struct KanbanDetailsView: View {
    let lines: [String]

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text("Details")
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                }
            }
            .buttonStyle(.palGlass)
            .accessibilityValue(Text(expanded ? "Expanded" : "Collapsed"))
            .accessibilityIdentifier("kanbanDetails-toggle")
            if expanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(PalTokens.textTertiary)
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("kanbanDetails")
            }
        }
        .padding(.horizontal, PalMetrics.screenMargin)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
