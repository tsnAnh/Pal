#if os(macOS)
import AppKit
import PalChat
import SwiftUI
import Testing

@testable import Pal

@MainActor
@Suite("Selectable text sizing")
struct SelectableTextSizingTests {
    private static let paragraph = "The **quick** brown fox jumps over the `lazy` dog while reading the "
        + "[documentation](https://example.com/docs) and thinking about how long a single message can become "
        + "when an assistant writes a thorough answer. "

    private static let sources = [
        "Hi",
        "",
        "Short line.\n\nSecond short line.",
        "> quoted words that wrap around in a narrow column, again and again and again.\n\nAfter the quote.",
        "- one\n- two with `code`\n  - nested item long enough to wrap in a narrow column for sure yes\n\n1. first\n2. second",
        "# Heading\n\n" + String(repeating: paragraph, count: 12),
        String(repeating: paragraph + "\n\n", count: 30),
    ]

    private static let widths: [CGFloat] = [1, 10_000, 90, 300, 534, 536, 900, 1915, 5000]

    private func texts(from source: String) -> [SelectableText] {
        SelectableTextPrefetcher.selectableTexts(in: MarkdownDocument(parsing: source).messageSegments)
    }

    private func fresh(_ text: SelectableText, width: CGFloat) -> CGSize {
        SelectableTextLayout.Session(SelectableTextLayout.attributed(for: text)).size(width: width)
    }

    @Test func everyCachedWidthMatchesAFreshLayoutExceptTheMinimumProbe() {
        for source in Self.sources {
            for text in texts(from: source) {
                let cache = SelectableSizeCache()
                cache.fill(text, widths: Self.widths) { SelectableTextLayout.attributed(for: text) }
                for width in Self.widths {
                    let cached = cache.size(for: text, width: width)
                    #expect(cached != nil, "\(source.prefix(20)) at \(width)")
                    if width > SelectableTextLayout.minimumWidth {
                        #expect(cached == fresh(text, width: width), "\(source.prefix(20)) at \(width)")
                    }
                }
            }
        }
    }

    @Test func theMinimumProbeNeverLaysOutOneGlyphPerLine() throws {
        let text = try #require(texts(from: String(repeating: Self.paragraph, count: 20)).first)
        let cache = SelectableSizeCache()
        cache.fill(text, widths: [SelectableTextLayout.minimumWidth]) { SelectableTextLayout.attributed(for: text) }
        let probe = try #require(cache.size(for: text, width: SelectableTextLayout.minimumWidth))
        let natural = try #require(cache.size(for: text, width: SelectableTextLayout.idealWidth))
        #expect(probe.height == natural.height)
        #expect(probe.width == SelectableTextLayout.minimumWidth)
    }

    @Test func aPrefetchedMessageNeedsNoLayoutWhenItsRowAppears() throws {
        let sizes = SelectableSizeCache()
        _ = sizes.noteRequested(width: 534)
        _ = sizes.noteRequested(width: 536)
        let prefetcher = SelectableTextPrefetcher(sizes: sizes)
        let markdown = DeferredMarkdown(Self.sources[4] + "\n\n> " + Self.paragraph + "\n\n" + Self.sources[5])
        prefetcher.enqueue(markdown)
        prefetcher.queue.sync {}
        let found = SelectableTextPrefetcher.selectableTexts(in: markdown.segments)
        #expect(found.count >= 3)
        for text in found {
            for width in [SelectableTextLayout.minimumWidth, SelectableTextLayout.idealWidth, 534, 536] {
                #expect(sizes.size(for: text, width: width) != nil)
            }
            #expect(sizes.size(for: text, width: 536) == fresh(text, width: 536))
        }
    }

    @Test func aWidthNobodyRequestedIsLeftForTheRowToMeasure() throws {
        let sizes = SelectableSizeCache()
        let prefetcher = SelectableTextPrefetcher(sizes: sizes)
        let markdown = DeferredMarkdown(Self.sources[5])
        prefetcher.enqueue(markdown)
        prefetcher.queue.sync {}
        let text = try #require(SelectableTextPrefetcher.selectableTexts(in: markdown.segments).first)
        #expect(sizes.size(for: text, width: 417) == nil)
    }

    @Test func layoutsOnBackgroundThreadsMatchTheMainThread() {
        let all = Self.sources.flatMap(texts(from:))
        let expected = all.map { text in Self.widths.map { fresh(text, width: $0) } }
        let results = ConcurrentResults(count: all.count)
        DispatchQueue.concurrentPerform(iterations: all.count * 4) { iteration in
            let index = iteration % all.count
            let session = SelectableTextLayout.Session(SelectableTextLayout.attributed(for: all[index]))
            results.record(index: iteration, sizes: Self.widths.map { session.size(width: $0) })
        }
        for (iteration, sizes) in results.all.enumerated() {
            #expect(sizes == expected[iteration % all.count], "iteration \(iteration)")
        }
    }

    @Test func aRowReflowsWhenTheWindowShrinks() throws {
        let source = String(repeating: Self.paragraph + "\n\n", count: 6)
        func parsedSegment() throws -> TextSegment {
            guard case .text(let segment) = try #require(MarkdownDocument(parsing: source).messageSegments.first) else { throw SizingError.noText }
            return segment
        }
        func content(width: CGFloat, segment: TextSegment) -> some View {
            MarkdownView(segment: segment, wholeBubbleSelection: true, highlight: "", isCurrentMatch: false)
                .frame(width: width, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        let segment = try parsedSegment()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        let wide = NSHostingView(rootView: content(width: 700, segment: segment))
        window.contentView = wide
        wide.layoutSubtreeIfNeeded()
        wide.displayIfNeeded()
        wide.rootView = content(width: 300, segment: segment)
        wide.layoutSubtreeIfNeeded()
        let shrunk = wide.fittingSize.height
        let reference = NSHostingView(rootView: content(width: 300, segment: try parsedSegment())).fittingSize.height
        #expect(shrunk == reference)
    }

    private enum SizingError: Error {
        case noText
    }
}

private final class ConcurrentResults: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [[CGSize]]

    init(count: Int) { stored = Array(repeating: [], count: count * 4) }

    func record(index: Int, sizes: [CGSize]) {
        lock.lock()
        stored[index] = sizes
        lock.unlock()
    }

    var all: [[CGSize]] { stored }
}
#endif
