import Foundation

public struct TextSegment: Sendable, Equatable {
    public let items: [MarkdownLayoutItem]
    public let runs: [MarkdownRun]
    public let spoken: String

    public init(items: [MarkdownLayoutItem]) {
        self.items = items
        runs = MarkdownRun.group(items)
        spoken = items
            .flatMap { item -> [MarkdownBlock] in
                switch item {
                case .block(let block): [block]
                case .quote(let blocks): blocks
                }
            }
            .map { String($0.text.characters) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

public enum MessageSegment: Sendable, Equatable, Identifiable {
    case text(TextSegment)
    case table(blockID: Int, MarkdownTable)

    public var id: String {
        switch self {
        case .text(let segment): "text\(segment.items.first?.id ?? "")"
        case .table(let blockID, _): "table\(blockID)"
        }
    }

    public static func split(_ items: [MarkdownLayoutItem]) -> [MessageSegment] {
        var segments: [MessageSegment] = []
        var pending: [MarkdownLayoutItem] = []
        func flush() {
            guard !pending.isEmpty else { return }
            segments.append(.text(TextSegment(items: pending)))
            pending = []
        }
        for item in items {
            if case .block(let block) = item, case .table(let table) = block.kind, block.lists.isEmpty {
                flush()
                segments.append(.table(blockID: block.id, table))
            } else {
                pending.append(item)
            }
        }
        flush()
        return segments
    }
}

public extension MarkdownDocument {
    var messageSegments: [MessageSegment] { MessageSegment.split(layoutItems) }
}

public enum MarkdownRun: Sendable, Equatable, Identifiable {
    case text(id: Int, SelectableText)
    case block(MarkdownBlock)
    case quote(id: Int, runs: [MarkdownRun])

    public var id: String {
        switch self {
        case .text(let id, _): "t\(id)"
        case .block(let block): "b\(block.id)"
        case .quote(let id, _): "q\(id)"
        }
    }

    public static func group(_ items: [MarkdownLayoutItem]) -> [MarkdownRun] {
        var runs: [MarkdownRun] = []
        var pending: [MarkdownBlock] = []
        func flush() {
            guard let first = pending.first else { return }
            runs.append(.text(id: first.id, SelectableText(blocks: pending)))
            pending = []
        }
        for item in items {
            switch item {
            case .block(let block):
                if block.isSelectableText {
                    pending.append(block)
                } else {
                    flush()
                    runs.append(.block(block))
                }
            case .quote(let blocks):
                flush()
                runs.append(.quote(id: blocks.first?.id ?? 0, runs: group(blocks.map(MarkdownLayoutItem.block))))
            }
        }
        flush()
        return runs
    }
}

extension MarkdownBlock {
    var isSelectableText: Bool {
        switch kind {
        case .heading:
            return true
        case .paragraph:
            guard isComplete, let link = standaloneLink else { return true }
            return !MediaLink.isInlinePlayableVideo(link) && EmbedDetector.detect(link) == nil
        case .code, .math, .thematicBreak, .table:
            return false
        }
    }
}

public struct SelectableParagraph: Sendable, Equatable {
    public enum Style: Sendable, Equatable {
        case body
        case heading(level: Int)
    }

    public var style: Style
    public var text: AttributedString
    public var listDepth: Int
    public var marker: String

    public init(style: Style, text: AttributedString, listDepth: Int, marker: String) {
        self.style = style
        self.text = text
        self.listDepth = listDepth
        self.marker = marker
    }

    public init(_ block: MarkdownBlock) {
        let style: Style
        if case .heading(let level) = block.kind { style = .heading(level: level) } else { style = .body }
        var marker = ""
        if block.startsListItem, let list = block.lists.last {
            marker = list.style == .ordered ? "\(list.ordinal)." : "•"
        }
        self.init(style: style, text: block.text, listDepth: block.lists.count, marker: marker)
    }

    public var plainText: String {
        (marker.isEmpty ? "" : "\(marker)\t") + String(text.characters)
    }
}

public struct SelectableText: Sendable, Equatable {
    public let paragraphs: [SelectableParagraph]

    public init(blocks: [MarkdownBlock]) {
        paragraphs = blocks.map(SelectableParagraph.init)
    }

    public var plainText: String {
        paragraphs.map(\.plainText).joined(separator: "\n")
    }
}
