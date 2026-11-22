import Foundation
import PalDiagnostics

public final class DeferredMarkdown: @unchecked Sendable {
    private let source: String
    private let parse: (@Sendable (String) -> MarkdownDocument)?
    private let lock = NSLock()
    private var parsed: MarkdownDocument?
    private var split: [MessageSegment]?

    public init(_ source: String) {
        self.source = source
        self.parse = nil
    }

    init(_ source: String, parse: @escaping @Sendable (String) -> MarkdownDocument) {
        self.source = source
        self.parse = parse
    }

    public init(_ source: String, parsed: MarkdownDocument) {
        self.source = source
        self.parse = nil
        self.parsed = parsed
        self.split = parsed.messageSegments
    }

    public var document: MarkdownDocument { resolved(remember: true).document }

    public var segments: [MessageSegment] { resolved(remember: true).segments }

    private func resolved(remember: Bool) -> (document: MarkdownDocument, segments: [MessageSegment]) {
        lock.lock()
        defer { lock.unlock() }
        if let parsed, let split { return (parsed, split) }
        if Thread.isMainThread { PalPerf.event("markdown.resolve.main") }
        let document = parsed ?? parse?(source) ?? IncrementalMarkdown.shared.document(for: source, remember: remember)
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

    func warm() {
        PalPerf.interval("markdown.warm") { _ = resolved(remember: false) }
    }
}

public final class MarkdownWarmer: @unchecked Sendable {
    public static let shared = MarkdownWarmer()

    private struct Pending {
        weak var markdown: DeferredMarkdown?
    }

    private static let minimumPruneCount = 1024

    private let queue: DispatchQueue
    private let lock = NSLock()
    private var pending: [Pending] = []
    private var prioritized: [Pending] = []
    private var pruneCount = MarkdownWarmer.minimumPruneCount
    private var draining = false

    public init(qos: DispatchQoS = .userInitiated) {
        queue = DispatchQueue(label: "app.pal.markdown-warm", qos: qos)
    }

    public func enqueue(_ markdown: DeferredMarkdown) {
        lock.lock()
        pending.append(Pending(markdown: markdown))
        if pending.count >= pruneCount {
            pending.removeAll { $0.markdown?.isParsed ?? true }
            pruneCount = max(Self.minimumPruneCount, pending.count * 2)
        }
        let needsDrain = !draining
        draining = true
        lock.unlock()
        if needsDrain { queue.async { self.drain() } }
    }

    public func prioritize(_ rows: [DeferredMarkdown]) {
        lock.lock()
        defer { lock.unlock() }
        var moved: [Pending] = []
        for row in rows where !row.isParsed {
            if let index = prioritized.lastIndex(where: { $0.markdown === row }) {
                moved.append(prioritized.remove(at: index))
            } else if let index = pending.lastIndex(where: { $0.markdown === row }) {
                moved.append(pending.remove(at: index))
            }
        }
        prioritized.append(contentsOf: moved.reversed())
    }

    private func drain() {
        while let next = popNext() { next.markdown?.warm() }
    }

    private func popNext() -> Pending? {
        lock.lock()
        defer { lock.unlock() }
        guard let next = prioritized.popLast() ?? pending.popLast() else {
            draining = false
            return nil
        }
        return next
    }
}
