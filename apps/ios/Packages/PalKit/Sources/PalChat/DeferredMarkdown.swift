import Foundation

public final class DeferredMarkdown: @unchecked Sendable {
    private let source: String
    private let parse: @Sendable (String) -> MarkdownDocument
    private let lock = NSLock()
    private var parsed: MarkdownDocument?
    private var split: [MessageSegment]?

    public init(_ source: String, parse: @escaping @Sendable (String) -> MarkdownDocument = { MarkdownDocument(parsing: $0) }) {
        self.source = source
        self.parse = parse
    }

    public init(_ source: String, parsed: MarkdownDocument) {
        self.source = source
        self.parse = { MarkdownDocument(parsing: $0) }
        self.parsed = parsed
        self.split = parsed.messageSegments
    }

    public var document: MarkdownDocument { resolved().document }

    public var segments: [MessageSegment] { resolved().segments }

    private func resolved() -> (document: MarkdownDocument, segments: [MessageSegment]) {
        lock.lock()
        defer { lock.unlock() }
        if let parsed, let split { return (parsed, split) }
        let document = parsed ?? parse(source)
        let segments = document.messageSegments
        parsed = document
        split = segments
        return (document, segments)
    }

    public var isParsed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return parsed != nil
    }
}
