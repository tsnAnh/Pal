import Foundation

public final class DeferredMarkdown: @unchecked Sendable {
    private let source: String
    private let parse: @Sendable (String) -> MarkdownDocument
    private let lock = NSLock()
    private var parsed: MarkdownDocument?

    public init(_ source: String, parse: @escaping @Sendable (String) -> MarkdownDocument = { MarkdownDocument(parsing: $0) }) {
        self.source = source
        self.parse = parse
    }

    public init(_ source: String, parsed: MarkdownDocument) {
        self.source = source
        self.parse = { MarkdownDocument(parsing: $0) }
        self.parsed = parsed
    }

    public var document: MarkdownDocument {
        lock.lock()
        defer { lock.unlock() }
        if let parsed { return parsed }
        let document = parse(source)
        parsed = document
        return document
    }

    public var isParsed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return parsed != nil
    }
}
