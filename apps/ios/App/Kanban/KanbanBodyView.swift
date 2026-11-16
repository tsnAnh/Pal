import PalDesign
import PalKanban
import SwiftUI

struct KanbanBodyView: View {
    let document: KanbanBodyDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(document.blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
            if !document.metadata.isEmpty { metadata }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, PalMetrics.rowInset)
        .padding(.vertical, PalMetrics.rowVerticalPadding)
    }

    @ViewBuilder
    private func view(for block: KanbanBodyBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(Self.inline(text))
                .font(level <= 2 ? .headline : .subheadline.weight(.semibold))
                .foregroundStyle(PalTokens.textPrimary)
        case .paragraph(let text):
            Text(Self.inline(text))
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
                    Text(Self.inline(item)).foregroundStyle(PalTokens.textPrimary)
                }
                .hermesText(.chatBody)
            }
        }
    }

    private var metadata: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(document.metadata.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(PalTokens.textTertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        } label: {
            Text("Details").hermesText(.rowSubtitle).foregroundStyle(PalTokens.textSecondary)
        }
        .accessibilityIdentifier("kanbanMetadata")
    }

    static func inline(_ text: String) -> AttributedString {
        var result = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        let plain = String(result.characters)
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
}
