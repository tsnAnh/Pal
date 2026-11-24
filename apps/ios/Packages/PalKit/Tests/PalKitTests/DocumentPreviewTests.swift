@testable import PalChat
import Foundation
import Testing

private final class FakeDocumentGenerator: DocumentThumbnailGenerating, @unchecked Sendable {
    private let lock = NSLock()
    private let outcome: Result<GeneratedThumbnail?, any Error>
    private let delay: Duration
    private var started = 0
    private var running = 0
    private var peak = 0
    private var kinds: [ChatDocumentKind] = []

    init(outcome: Result<GeneratedThumbnail?, any Error>, delay: Duration = .zero) {
        self.outcome = outcome
        self.delay = delay
    }

    var calls: Int { lock.withLock { started } }
    var peakConcurrency: Int { lock.withLock { peak } }
    var seenKinds: [ChatDocumentKind] { lock.withLock { kinds } }

    func thumbnail(forFileAt url: URL, kind: ChatDocumentKind, maxPixel: Int) async throws -> GeneratedThumbnail? {
        lock.withLock {
            started += 1
            running += 1
            peak = max(peak, running)
            kinds.append(kind)
        }
        defer { lock.withLock { running -= 1 } }
        if delay > .zero { try await Task.sleep(for: delay) }
        return try outcome.get()
    }
}

private struct DocumentRig {
    let directory: URL
    let cache: MediaPosterCache
    let source: FakeMediaAssetSource
    let generator: FakeDocumentGenerator
    let resolver: DocumentPreviewResolver

    init(source: FakeMediaAssetSource, generator: FakeDocumentGenerator, queue: DocumentThumbnailQueue = DocumentThumbnailQueue()) {
        let directory = MediaFixtures.temporaryDirectory()
        let cache = MediaPosterCache(directory: directory)
        self.directory = directory
        self.cache = cache
        self.source = source
        self.generator = generator
        resolver = DocumentPreviewResolver(source: source, cache: cache, generator: generator, queue: queue)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private let thumbnail = GeneratedThumbnail(jpeg: Data([7, 7, 7]), pageCount: 12, width: 720, height: 1018)

private func report(size: Int? = nil) -> MediaReference {
    MediaFixtures.reference("Q3 report.pdf", kind: .pdf, size: size)
}

private func emptyAnswer() -> MediaPreviewAnswer {
    .unavailable(reason: "no_poster", MediaMetadata())
}

@Suite("Document kind and strip text")
struct DocumentKindTests {
    @Test("document extensions map to their kind regardless of case")
    func classification() {
        let expected: [ChatDocumentKind: [String]] = [
            .pdf: ["a.pdf", "b.PDF"],
            .office: ["a.docx", "b.XLSX", "c.pptx", "d.pages", "e.numbers", "f.key", "g.odt"],
            .text: ["a.txt", "b.md", "c.markdown", "d.rtf", "e.log"],
            .code: ["a.swift", "b.PY", "c.json", "d.yaml", "e.ts", "f.sql", "g.sh"],
            .csv: ["a.csv", "b.TSV"],
        ]
        for (kind, names) in expected {
            for name in names { #expect(ChatDocumentKind(fileName: name) == kind, "\(name) should be \(kind)") }
        }
    }

    @Test("html, archives, 3d, media and unknown files are not documents")
    func notDocuments() {
        for name in ["a.html", "b.htm", "c.zip", "d.usdz", "e.mp4", "f.mp3", "g.png", "h.vcf", "noextension", "i.bin"] {
            #expect(ChatDocumentKind(fileName: name) == nil, "\(name) is another unit's kind")
        }
    }

    @Test("the strip lists type, pages and size in that order")
    func stripDetail() {
        let strip = DocumentStrip(name: "Q3 report.pdf", typeLabel: "PDF", kind: .pdf, pageCount: 12, size: 2_400_000)
        #expect(strip.detail == "PDF, 12 pages, \(MediaSize.label(2_400_000))")
        #expect(DocumentStrip(name: "a.pdf", typeLabel: "PDF", kind: .pdf, pageCount: 1).detail == "PDF, 1 page")
        #expect(DocumentStrip(name: "a.txt", typeLabel: "TXT", kind: .text).detail == "TXT")
        #expect(DocumentStrip(name: "a.pdf", typeLabel: "PDF", kind: .pdf, pageCount: 0).detail == "PDF")
    }

    @Test("the accessibility label names kind, file and page count where known")
    func accessibilityLabel() {
        let known = DocumentStrip(name: "Q3 report.pdf", typeLabel: "PDF", kind: .pdf, pageCount: 12)
        #expect(known.accessibilityLabel == "PDF document, Q3 report.pdf, 12 pages")
        let unknown = DocumentStrip(name: "notes.txt", typeLabel: "TXT", kind: .text)
        #expect(unknown.accessibilityLabel == "Text file, notes.txt")
        #expect(DocumentStrip.openHint == "Double tap to open")
    }

    @Test("a resolved preview fills in pages and size")
    func stripFromPreview() {
        let base = DocumentStrip(name: "a.pdf", typeLabel: "PDF", kind: .pdf)
        let filled = base.with(MediaPreview(poster: nil, size: 500, pageCount: 3))
        #expect(filled.pageCount == 3)
        #expect(filled.size == 500)
        #expect(base.with(nil) == base)
    }
}

@Suite("Document preview resolver")
struct DocumentPreviewResolverTests {
    @Test("a downloaded copy is thumbnailed, cached and removed")
    func ready() async throws {
        let generator = FakeDocumentGenerator(outcome: .success(thumbnail))
        let rig = DocumentRig(source: FakeMediaAssetSource(answer: emptyAnswer(), payload: MediaFixtures.payload(count: 64)), generator: generator)
        defer { rig.cleanUp() }
        let reference = report()
        #expect(rig.resolver.cached(reference) == nil)
        let state = try await rig.resolver.resolve(reference, kind: .pdf)
        let expected = MediaPreview(poster: thumbnail.jpeg, size: 64, width: 720, height: 1018, pageCount: 12)
        #expect(state == .ready(expected))
        #expect(rig.resolver.cached(reference) == expected)
        #expect(generator.seenKinds == [.pdf])
    }

    @Test("a second resolve is a cache hit and never downloads or generates again")
    func cacheHit() async throws {
        let generator = FakeDocumentGenerator(outcome: .success(thumbnail))
        let rig = DocumentRig(source: FakeMediaAssetSource(answer: emptyAnswer(), payload: MediaFixtures.payload(count: 64)), generator: generator)
        defer { rig.cleanUp() }
        let first = try await rig.resolver.resolve(report(), kind: .pdf)
        let chunks = rig.source.chunkCalls
        let second = try await rig.resolver.resolve(report(), kind: .pdf)
        #expect(first == second)
        #expect(generator.calls == 1)
        #expect(rig.source.chunkCalls == chunks)
    }

    @Test("a fresh cache over the same folder serves the thumbnail from disk")
    func diskHit() async throws {
        let generator = FakeDocumentGenerator(outcome: .success(thumbnail))
        let rig = DocumentRig(source: FakeMediaAssetSource(answer: emptyAnswer(), payload: MediaFixtures.payload(count: 64)), generator: generator)
        defer { rig.cleanUp() }
        let first = try await rig.resolver.resolve(report(), kind: .pdf)
        let reopened = DocumentPreviewResolver(
            source: rig.source, cache: MediaPosterCache(directory: rig.directory), generator: generator, queue: DocumentThumbnailQueue()
        )
        let second = try await reopened.resolve(report(), kind: .pdf)
        #expect(second == first)
        #expect(generator.calls == 1)
    }

    @Test("a known size over the thumbnail ceiling is too large without any download")
    func tooLargeBySize() async throws {
        let generator = FakeDocumentGenerator(outcome: .success(thumbnail))
        let rig = DocumentRig(source: FakeMediaAssetSource(answer: emptyAnswer()), generator: generator)
        defer { rig.cleanUp() }
        let state = try await rig.resolver.resolve(report(size: MediaLimits.thumbnailSourceBytes + 1), kind: .pdf)
        #expect(state == .tooLarge(size: MediaLimits.thumbnailSourceBytes + 1))
        #expect(rig.source.chunkCalls == 0)
        #expect(generator.calls == 0)
    }

    @Test("a size learned from the first chunk stops the download and is too large")
    func tooLargeByFirstChunk() async throws {
        let total = MediaLimits.thumbnailSourceBytes + 5
        let generator = FakeDocumentGenerator(outcome: .success(thumbnail))
        let source = FakeMediaAssetSource(answer: emptyAnswer(), payload: MediaFixtures.payload(count: 8), reportedTotal: total)
        let rig = DocumentRig(source: source, generator: generator)
        defer { rig.cleanUp() }
        let state = try await rig.resolver.resolve(report(), kind: .pdf)
        #expect(state == .tooLarge(size: total))
        #expect(source.chunkCalls == 1)
        #expect(generator.calls == 0)
    }

    @Test("the exact ceiling still gets a thumbnail")
    func ceilingIsInclusive() {
        #expect(MediaLimits.allowsThumbnail(size: MediaLimits.thumbnailSourceBytes))
        #expect(!MediaLimits.allowsThumbnail(size: MediaLimits.thumbnailSourceBytes + 1))
    }

    @Test("a transient transfer failure fails with its real reason, retries, and then succeeds")
    func failedThenRetried() async throws {
        let generator = FakeDocumentGenerator(outcome: .success(thumbnail))
        let source = FakeMediaAssetSource(answer: emptyAnswer(), payload: MediaFixtures.payload(count: 64))
        source.setChunkFailure(MediaFixtures.rpc(5151))
        let rig = DocumentRig(source: source, generator: generator)
        defer { rig.cleanUp() }
        let failed = try await rig.resolver.resolve(report(), kind: .pdf)
        let reason = FileLoadFailure(cause: .internalFailure).message
        #expect(failed == .failed(reason: reason, retryable: true))

        var loader = MediaPreviewLoader()
        let started = loader.start()
        loader.finish(failed)
        let retried = loader.retry()
        #expect(started && retried)
        source.setChunkFailure(nil)
        let again = try await rig.resolver.resolve(report(), kind: .pdf)
        loader.finish(again)
        guard case .ready = loader.state else {
            Issue.record("retry did not reach ready: \(loader.state)")
            return
        }
    }

    @Test("a missing file is a permanent failure with its own reason")
    func notFound() async throws {
        let source = FakeMediaAssetSource(answer: emptyAnswer())
        source.setChunkFailure(MediaFixtures.rpc(4151))
        let rig = DocumentRig(source: source, generator: FakeDocumentGenerator(outcome: .success(thumbnail)))
        defer { rig.cleanUp() }
        let state = try await rig.resolver.resolve(report(), kind: .pdf)
        #expect(state == .failed(reason: FileLoadFailure(cause: .notFound).message, retryable: false))
    }

    @Test("a generator that finds nothing is ready without a poster and is cached")
    func noThumbnail() async throws {
        let generator = FakeDocumentGenerator(outcome: .success(nil))
        let rig = DocumentRig(source: FakeMediaAssetSource(answer: emptyAnswer(), payload: MediaFixtures.payload(count: 16)), generator: generator)
        defer { rig.cleanUp() }
        let state = try await rig.resolver.resolve(report(), kind: .text)
        #expect(state == .ready(MediaPreview(poster: nil, size: 16)))
        _ = try await rig.resolver.resolve(report(), kind: .text)
        #expect(generator.calls == 1)
    }

    @Test("a generator error is ready without a poster and is not cached")
    func generatorError() async throws {
        struct Boom: Error {}
        let generator = FakeDocumentGenerator(outcome: .failure(Boom()))
        let rig = DocumentRig(source: FakeMediaAssetSource(answer: emptyAnswer(), payload: MediaFixtures.payload(count: 16)), generator: generator)
        defer { rig.cleanUp() }
        let state = try await rig.resolver.resolve(report(), kind: .code)
        #expect(state == .ready(MediaPreview(poster: nil, size: 16)))
        #expect(rig.resolver.cached(report()) == nil)
        _ = try await rig.resolver.resolve(report(), kind: .code)
        #expect(generator.calls == 2)
    }

    @Test("only one thumbnail is generated at a time")
    func serial() async throws {
        let generator = FakeDocumentGenerator(outcome: .success(thumbnail), delay: .milliseconds(30))
        let rig = DocumentRig(source: FakeMediaAssetSource(answer: emptyAnswer(), payload: MediaFixtures.payload(count: 16)), generator: generator)
        defer { rig.cleanUp() }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<4 {
                group.addTask {
                    let reference = MediaFixtures.reference("doc\(index).pdf", kind: .pdf)
                    _ = try await rig.resolver.resolve(reference, kind: .pdf)
                }
            }
            try await group.waitForAll()
        }
        #expect(generator.calls == 4)
        #expect(generator.peakConcurrency == 1)
    }

    @Test("a document that scrolls off while waiting is cancelled and never generated")
    func cancelWhileQueued() async throws {
        let generator = FakeDocumentGenerator(outcome: .success(thumbnail), delay: .milliseconds(200))
        let rig = DocumentRig(source: FakeMediaAssetSource(answer: emptyAnswer(), payload: MediaFixtures.payload(count: 16)), generator: generator)
        defer { rig.cleanUp() }
        let running = Task { try await rig.resolver.resolve(MediaFixtures.reference("first.pdf", kind: .pdf), kind: .pdf) }
        try await Task.sleep(for: .milliseconds(50))
        let waiting = Task { try await rig.resolver.resolve(MediaFixtures.reference("second.pdf", kind: .pdf), kind: .pdf) }
        try await Task.sleep(for: .milliseconds(30))
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
        _ = try await running.value
        #expect(generator.calls == 1)

        var loader = MediaPreviewLoader()
        let started = loader.start()
        #expect(started)
        loader.cancel()
        #expect(loader.state == .idle)
    }
}
