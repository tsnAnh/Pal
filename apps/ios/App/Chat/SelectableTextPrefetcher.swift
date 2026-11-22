#if os(macOS)
import Foundation
import PalChat
import PalDiagnostics

final class SelectableTextPrefetcher: @unchecked Sendable {
    static let shared = SelectableTextPrefetcher(sizes: .shared)

    private static let settleDelay: DispatchTimeInterval = .milliseconds(120)

    private struct Entry {
        weak var markdown: DeferredMarkdown?
    }

    let queue = DispatchQueue(label: "app.pal.selectable-prefetch", qos: .userInitiated)

    private let sizes: SelectableSizeCache
    private let capacity: Int
    private let lock = NSLock()
    private var pending: [Entry] = []
    private var known: [Entry] = []
    private var draining = false
    private var widthEpoch = 0

    init(sizes: SelectableSizeCache, capacity: Int = 400) {
        self.sizes = sizes
        self.capacity = capacity
    }

    func enqueue(_ markdown: DeferredMarkdown) {
        let entry = Entry(markdown: markdown)
        lock.lock()
        pending.append(entry)
        known.append(entry)
        if pending.count > capacity { pending.removeFirst(pending.count - capacity) }
        if known.count > capacity { known.removeFirst(known.count - capacity) }
        scheduleDrainLocked()
        lock.unlock()
    }

    func widthsChanged() {
        lock.lock()
        widthEpoch += 1
        let epoch = widthEpoch
        lock.unlock()
        queue.asyncAfter(deadline: .now() + Self.settleDelay) { self.rescan(epoch: epoch) }
    }

    private func rescan(epoch: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard epoch == widthEpoch else { return }
        pending = known
        scheduleDrainLocked()
    }

    private func scheduleDrainLocked() {
        guard !draining, !pending.isEmpty else { return }
        draining = true
        queue.async { self.drain() }
    }

    private func drain() {
        while let next = popNewest() {
            guard let markdown = next.markdown else { continue }
            prefetch(markdown)
        }
    }

    private func popNewest() -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        guard let newest = pending.popLast() else {
            draining = false
            return nil
        }
        return newest
    }

    private func prefetch(_ markdown: DeferredMarkdown) {
        let widths = [SelectableTextLayout.minimumWidth, SelectableTextLayout.idealWidth] + sizes.recentWidths
        for text in Self.selectableTexts(in: markdown.segments) {
            PalPerf.interval("selectable.prefetch") {
                sizes.fill(text, widths: widths) { SelectableTextLayout.attributed(for: text) }
            }
        }
    }

    static func selectableTexts(in segments: [MessageSegment]) -> [SelectableText] {
        segments.flatMap { segment -> [SelectableText] in
            guard case .text(let text) = segment else { return [] }
            return selectableTexts(in: text.runs)
        }
    }

    private static func selectableTexts(in runs: [MarkdownRun]) -> [SelectableText] {
        runs.flatMap { run -> [SelectableText] in
            switch run {
            case .text(_, let text): [text]
            case .block: []
            case .quote(_, let inner): selectableTexts(in: inner)
            }
        }
    }
}
#endif
