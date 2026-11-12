import Foundation

public struct ListMarker: Sendable, Hashable {
    public enum Style: Sendable, Hashable {
        case bullet
        case ordered
    }

    public var style: Style
    public var ordinal: Int

    public init(style: Style, ordinal: Int) {
        self.style = style
        self.ordinal = ordinal
    }
}

public struct MarkdownBlock: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case paragraph
        case heading(level: Int)
        case code(language: String?)
        case thematicBreak
        case math
        case table(MarkdownTable)
    }

    public var id: Int
    public var kind: Kind
    public var text: AttributedString
    public var lists: [ListMarker]
    public var startsListItem: Bool
    public var quoteIdentity: Int?
    public var isQuoted: Bool { quoteIdentity != nil }
    public var isComplete: Bool = true

    public init(
        id: Int,
        kind: Kind,
        text: AttributedString,
        lists: [ListMarker] = [],
        startsListItem: Bool = false,
        quoteIdentity: Int? = nil,
        isComplete: Bool = true
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.lists = lists
        self.startsListItem = startsListItem
        self.quoteIdentity = quoteIdentity
        self.isComplete = isComplete
    }
}

public enum MarkdownLayoutItem: Sendable, Equatable, Identifiable {
    case block(MarkdownBlock)
    case quote(blocks: [MarkdownBlock])

    public var id: String {
        switch self {
        case .block(let block): "b\(block.id)"
        case .quote(let blocks): "q\(blocks.first?.id ?? 0)"
        }
    }
}

public struct MarkdownDocument: Sendable, Equatable {
    public private(set) var blocks: [MarkdownBlock]

    public init(parsing source: String, isStreaming: Bool = false) {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            blocks = []
            return
        }
        guard let segments = MarkdownSegmenter.segments(in: source, isStreaming: isStreaming) else {
            blocks = Self.parsedBlocks(source)
            return
        }
        var built: [MarkdownBlock] = []
        for segment in segments {
            switch segment {
            case .text(let text):
                built.append(contentsOf: Self.parsedBlocks(text))
            case .math(let tex, let isComplete):
                built.append(MarkdownBlock(id: 0, kind: .math, text: AttributedString(tex), isComplete: isComplete))
            case .code(let language, let body):
                built.append(MarkdownBlock(id: 0, kind: .code(language: language), text: AttributedString(body), isComplete: false))
            }
        }
        for index in built.indices { built[index].id = index }
        blocks = built
    }

    public var layoutItems: [MarkdownLayoutItem] {
        var items: [MarkdownLayoutItem] = []
        var openQuote: (identity: Int, blocks: [MarkdownBlock])?
        func closeQuote() {
            if let quote = openQuote { items.append(.quote(blocks: quote.blocks)) }
            openQuote = nil
        }
        for block in blocks {
            guard let identity = block.quoteIdentity else {
                closeQuote()
                items.append(.block(block))
                continue
            }
            if openQuote?.identity != identity { closeQuote() }
            openQuote = (identity, (openQuote?.blocks ?? []) + [block])
        }
        closeQuote()
        return items
    }

    private static func parsedBlocks(_ source: String) -> [MarkdownBlock] {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard let attributed = try? AttributedString(markdown: source, options: options) else {
            return [fallbackBlock(source)]
        }
        return blocks(from: attributed)
    }

    private static func fallbackBlock(_ source: String) -> MarkdownBlock {
        MarkdownBlock(id: 0, kind: .paragraph, text: AttributedString(source), lists: [], startsListItem: false)
    }

    private struct Leaf {
        var identity: Int
        var intent: PresentationIntent?
        var range: Range<AttributedString.Index>
    }

    private static func blocks(from attributed: AttributedString) -> [MarkdownBlock] {
        var leaves: [Leaf] = []
        for run in attributed.runs {
            let intent = run.presentationIntent
            let identity = intent?.components.first?.identity ?? -1
            if let last = leaves.last, last.identity == identity {
                leaves[leaves.count - 1].range = last.range.lowerBound..<run.range.upperBound
            } else {
                leaves.append(Leaf(identity: identity, intent: intent, range: run.range))
            }
        }
        var seenItems: Set<Int> = []
        var built: [MarkdownBlock] = []
        var openTable: TableBuilder?
        for leaf in leaves {
            let components = leaf.intent?.components ?? []
            if let cell = TableBuilder.cell(in: components) {
                let cellText = text(of: attributed, range: leaf.range, kind: .paragraph)
                if var open = openTable, open.identity == cell.tableIdentity {
                    open.add(cell, cellText)
                    openTable = open
                    built[built.count - 1].kind = .table(open.table)
                    continue
                }
                var builder = TableBuilder(identity: cell.tableIdentity, alignments: cell.alignments)
                builder.add(cell, cellText)
                openTable = builder
                built.append(tableBlock(id: built.count, builder: builder, components: components, seenItems: &seenItems))
                continue
            }
            openTable = nil
            guard let kind = kind(of: components.first?.kind) else { continue }
            let context = context(of: components, seenItems: &seenItems)
            built.append(MarkdownBlock(
                id: built.count,
                kind: kind,
                text: text(of: attributed, range: leaf.range, kind: kind),
                lists: context.lists,
                startsListItem: context.startsItem,
                quoteIdentity: context.quoteIdentity
            ))
        }
        return built
    }

    private static func tableBlock(id: Int, builder: TableBuilder, components: [PresentationIntent.IntentType], seenItems: inout Set<Int>) -> MarkdownBlock {
        let context = context(of: components, seenItems: &seenItems)
        return MarkdownBlock(
            id: id,
            kind: .table(builder.table),
            text: AttributedString(),
            lists: context.lists,
            startsListItem: context.startsItem,
            quoteIdentity: context.quoteIdentity
        )
    }

    private static func context(
        of components: [PresentationIntent.IntentType],
        seenItems: inout Set<Int>
    ) -> (lists: [ListMarker], startsItem: Bool, quoteIdentity: Int?) {
        var lists: [ListMarker] = []
        var quoteIdentity: Int?
        var itemIdentity: Int?
        for component in components.dropFirst().reversed() {
            switch component.kind {
            case .orderedList:
                lists.append(ListMarker(style: .ordered, ordinal: 1))
            case .unorderedList:
                lists.append(ListMarker(style: .bullet, ordinal: 1))
            case .listItem(let ordinal):
                itemIdentity = component.identity
                if let index = lists.indices.last { lists[index].ordinal = ordinal }
            case .blockQuote:
                if quoteIdentity == nil { quoteIdentity = component.identity }
            default:
                break
            }
        }
        let startsItem: Bool
        if let itemIdentity { startsItem = seenItems.insert(itemIdentity).inserted } else { startsItem = false }
        return (lists, startsItem, quoteIdentity)
    }

    private static func kind(of component: PresentationIntent.Kind?) -> MarkdownBlock.Kind? {
        switch component {
        case .none, .paragraph: .paragraph
        case .header(let level): .heading(level: level)
        case .codeBlock(let language): .code(language: language.flatMap { $0.isEmpty ? nil : $0 })
        case .thematicBreak: .thematicBreak
        default: .paragraph
        }
    }

    private static func text(of source: AttributedString, range: Range<AttributedString.Index>, kind: MarkdownBlock.Kind) -> AttributedString {
        var copy = AttributedString(source[range])
        copy.presentationIntent = nil
        switch kind {
        case .code:
            if copy.characters.last == "\n" { copy.characters.removeLast() }
        case .thematicBreak:
            copy = AttributedString()
        default:
            for run in copy.runs.reversed() {
                guard let intent = run.inlinePresentationIntent, intent.contains(.softBreak) || intent.contains(.lineBreak) else { continue }
                copy.replaceSubrange(run.range, with: AttributedString("\n"))
            }
        }
        return copy
    }

    private struct TableBuilder {
        struct Cell {
            var tableIdentity: Int
            var alignments: [MarkdownTable.Alignment]
            var rowIdentity: Int
            var isHeader: Bool
            var column: Int
        }

        var identity: Int
        var alignments: [MarkdownTable.Alignment]
        var header: [Int: AttributedString] = [:]
        var rowOrder: [Int] = []
        var rows: [Int: [Int: AttributedString]] = [:]

        static func cell(in components: [PresentationIntent.IntentType]) -> Cell? {
            var column: Int?
            var rowIdentity: Int?
            var isHeader = false
            for component in components {
                switch component.kind {
                case .tableCell(let index): column = index
                case .tableHeaderRow:
                    rowIdentity = component.identity
                    isHeader = true
                case .tableRow: rowIdentity = component.identity
                case .table(let columns):
                    guard let column, let rowIdentity else { return nil }
                    return Cell(
                        tableIdentity: component.identity,
                        alignments: columns.map { $0.alignment.markdownAlignment },
                        rowIdentity: rowIdentity,
                        isHeader: isHeader,
                        column: column
                    )
                default: break
                }
            }
            return nil
        }

        mutating func add(_ cell: Cell, _ text: AttributedString) {
            if cell.isHeader {
                header[cell.column] = text
                return
            }
            if rows[cell.rowIdentity] == nil { rowOrder.append(cell.rowIdentity) }
            rows[cell.rowIdentity, default: [:]][cell.column] = text
        }

        var table: MarkdownTable {
            let width = max(alignments.count, (header.keys.max() ?? -1) + 1)
            func dense(_ cells: [Int: AttributedString]) -> [AttributedString] {
                (0..<width).map { cells[$0] ?? AttributedString() }
            }
            return MarkdownTable(
                alignments: alignments,
                header: dense(header),
                rows: rowOrder.map { dense(rows[$0] ?? [:]) }
            )
        }
    }
}

private extension PresentationIntent.TableColumn.Alignment {
    var markdownAlignment: MarkdownTable.Alignment {
        switch self {
        case .left: .leading
        case .center: .center
        case .right: .trailing
        @unknown default: .leading
        }
    }
}
