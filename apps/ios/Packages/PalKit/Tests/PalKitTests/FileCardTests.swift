@testable import PalChat
import Foundation
import Testing

private final class ModelGenerator: DocumentThumbnailGenerating, @unchecked Sendable {
    private let lock = NSLock()
    private var kinds: [ChatDocumentKind?] = []
    private let outcome: GeneratedThumbnail?

    init(outcome: GeneratedThumbnail?) {
        self.outcome = outcome
    }

    var seenKinds: [ChatDocumentKind?] { lock.withLock { kinds } }

    func thumbnail(forFileAt url: URL, kind: ChatDocumentKind?, maxPixel: Int) async throws -> GeneratedThumbnail? {
        lock.withLock { kinds.append(kind) }
        return outcome
    }
}

private struct FileCardRig {
    let directory = MediaFixtures.temporaryDirectory()
    let resolver: FileCardResolver

    init(source: FakeMediaAssetSource, generator: ModelGenerator = ModelGenerator(outcome: nil)) {
        let cache = MediaPosterCache(directory: directory)
        let media = MediaPreviewResolver(source: source, cache: cache, generator: nil)
        resolver = FileCardResolver(
            media: media, documents: DocumentPreviewResolver(source: source, cache: cache, generator: generator, queue: DocumentThumbnailQueue())
        )
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private func archive(size: Int? = nil) -> MediaReference {
    MediaFixtures.reference("logs.zip", kind: .archive, size: size)
}

private func model(size: Int? = nil) -> MediaReference {
    MediaFixtures.reference("chair.usdz", kind: .model3D, size: size)
}

private func answer(size: Int?) -> MediaPreviewAnswer {
    .unavailable(reason: "no_poster", MediaMetadata(size: size))
}

@Suite("File card kinds and strip text")
struct FileCardKindTests {
    @Test("archives, 3d models and unknown files each get their own icon card kind")
    func classification() {
        let expected: [(String, FileCardKind)] = [
            ("a.zip", .archive), ("b.TAR", .archive), ("c.gz", .archive), ("d.7z", .archive), ("e.tar.gz", .archive),
            ("a.usdz", .model3D), ("b.OBJ", .model3D), ("c.stl", .model3D),
            ("a.bin", .other), ("noextension", .other), ("b.exe", .other),
            ("a.pdf", .document(.pdf)), ("b.docx", .document(.office)), ("c.swift", .document(.code)),
        ]
        for (name, kind) in expected { #expect(FileCardKind(fileName: name) == kind, "\(name) should be \(kind)") }
    }

    @Test("html and htm are document cards that thumbnail like a pdf")
    func htmlIsADocumentCard() {
        for name in ["page.html", "PAGE.HTM"] {
            let kind = FileCardKind(fileName: name)
            #expect(kind == .document(.html), "\(name)")
            #expect(kind.hasThumbnail)
        }
    }

    @Test("every kind has a spoken name and an icon, and only documents and 3d models thumbnail")
    func spokenNamesIconsAndThumbnails() {
        let kinds: [FileCardKind] = [.archive, .model3D, .other, .document(.pdf)]
        for kind in kinds {
            #expect(!kind.spokenName.isEmpty)
            #expect(!kind.iconName.isEmpty)
        }
        #expect(FileCardKind.archive.spokenName == "Archive")
        #expect(FileCardKind.model3D.spokenName == "3D model")
        #expect(FileCardKind.other.spokenName == "File")
        #expect(kinds.filter(\.hasThumbnail) == [.model3D, .document(.pdf)])
    }

    @Test("the archive strip reads Archive and the size")
    func archiveStrip() {
        let file = FileReference(path: "/h/logs.zip", directive: "MEDIA:/h/logs.zip")
        let kind = FileCardKind(fileName: file.name)
        let strip = DocumentStrip(name: file.name, typeLabel: kind.typeLabel(of: file), kind: kind, size: 3_100_000)
        #expect(strip.detail == "Archive, \(MediaSize.label(3_100_000))")
        #expect(strip.accessibilityLabel == "Archive, logs.zip, \(MediaSize.label(3_100_000))")
    }

    @Test("an unknown file keeps its extension as the type")
    func unknownStrip() {
        let file = FileReference(path: "/h/data.bin", directive: "MEDIA:/h/data.bin")
        let kind = FileCardKind(fileName: file.name)
        #expect(DocumentStrip(name: file.name, typeLabel: kind.typeLabel(of: file), kind: kind).detail == "BIN")
        #expect(DocumentStrip(name: file.name, typeLabel: kind.typeLabel(of: file), kind: kind).accessibilityLabel == "File, data.bin")
    }
}

@Suite("File card resolver")
struct FileCardResolverTests {
    @Test("an archive resolves from the preview answer with its size and never downloads")
    func archiveReady() async throws {
        let source = FakeMediaAssetSource(answer: answer(size: 3_100_000))
        let rig = FileCardRig(source: source)
        defer { rig.cleanUp() }
        let state = try await rig.resolver.resolve(archive(), kind: .archive)
        #expect(state == .ready(MediaPreview(poster: nil, size: 3_100_000)))
        #expect(source.chunkCalls == 0)
        #expect(rig.resolver.cached(archive(), kind: .archive) == MediaPreview(poster: nil, size: 3_100_000))
    }

    @Test("an archive over the download ceiling offers Download")
    func archiveTooLarge() async throws {
        let rig = FileCardRig(source: FakeMediaAssetSource(answer: answer(size: MediaLimits.downloadBytes + 1)))
        defer { rig.cleanUp() }
        let state = try await rig.resolver.resolve(archive(), kind: .archive)
        #expect(state == .tooLarge(size: MediaLimits.downloadBytes + 1))
    }

    @Test("a 3d model is thumbnailed from a downloaded copy with no document kind")
    func modelThumbnail() async throws {
        let thumbnail = GeneratedThumbnail(jpeg: Data([4, 4]), pageCount: nil, width: 720, height: 1080)
        let generator = ModelGenerator(outcome: thumbnail)
        let source = FakeMediaAssetSource(answer: answer(size: nil), payload: MediaFixtures.payload(count: 32))
        let rig = FileCardRig(source: source, generator: generator)
        defer { rig.cleanUp() }
        let state = try await rig.resolver.resolve(model(), kind: .model3D)
        #expect(state == .ready(MediaPreview(poster: thumbnail.jpeg, size: 32, width: 720, height: 1080)))
        #expect(generator.seenKinds == [nil])
        #expect(rig.resolver.cached(model(), kind: .model3D) != nil)
    }

    @Test("a 3d model the system cannot thumbnail falls back to the icon card")
    func modelWithoutThumbnail() async throws {
        let source = FakeMediaAssetSource(answer: answer(size: nil), payload: MediaFixtures.payload(count: 32))
        let rig = FileCardRig(source: source)
        defer { rig.cleanUp() }
        let state = try await rig.resolver.resolve(model(), kind: .model3D)
        #expect(state == .ready(MediaPreview(poster: nil, size: 32)))
    }

    @Test("a 3d model over the thumbnail ceiling offers Download without fetching")
    func modelTooLarge() async throws {
        let source = FakeMediaAssetSource(answer: answer(size: nil), payload: MediaFixtures.payload(count: 8))
        let rig = FileCardRig(source: source)
        defer { rig.cleanUp() }
        let state = try await rig.resolver.resolve(model(size: MediaLimits.thumbnailSourceBytes + 1), kind: .model3D)
        #expect(state == .tooLarge(size: MediaLimits.thumbnailSourceBytes + 1))
        #expect(source.chunkCalls == 0)
    }

    @Test("every kind reports the real reason, retryable only when the cause is transient")
    func failures() async throws {
        let kinds: [(FileCardKind, MediaReference)] = [(.archive, archive()), (.other, MediaFixtures.reference("a.bin", kind: .other))]
        for (kind, reference) in kinds {
            let unreachable = FileCardRig(source: FakeMediaAssetSource(failure: URLError(.notConnectedToInternet)))
            defer { unreachable.cleanUp() }
            let state = try await unreachable.resolver.resolve(reference, kind: kind)
            #expect(state == .failed(reason: FileLoadFailure(cause: .unreachable).message, retryable: true))

            let missing = FileCardRig(source: FakeMediaAssetSource(failure: MediaFixtures.rpc(4151)))
            defer { missing.cleanUp() }
            let gone = try await missing.resolver.resolve(reference, kind: kind)
            #expect(gone == .failed(reason: FileLoadFailure(cause: .notFound).message, retryable: false))
        }
    }

    @Test("a 3d model download that fails reports the reason")
    func modelFailure() async throws {
        let source = FakeMediaAssetSource(answer: answer(size: nil), payload: MediaFixtures.payload(count: 8))
        source.setChunkFailure(MediaFixtures.rpc(4151))
        let rig = FileCardRig(source: source)
        defer { rig.cleanUp() }
        let state = try await rig.resolver.resolve(model(), kind: .model3D)
        #expect(state == .failed(reason: FileLoadFailure(cause: .notFound).message, retryable: false))
    }
}

@Suite("Media accessibility labels")
struct MediaAccessibilityTests {
    @Test("a video names its kind, file and spoken duration")
    func video() {
        #expect(MediaAccessibility.video(name: "clip.mp4", duration: 42) == "Video, clip.mp4, 42 seconds")
        #expect(MediaAccessibility.video(name: "clip.mp4", duration: 65) == "Video, clip.mp4, 1 minute, 5 seconds")
        #expect(MediaAccessibility.video(name: "clip.mp4", duration: nil) == "Video, clip.mp4")
        #expect(MediaAccessibility.video(name: "clip.mp4", duration: 0) == "Video, clip.mp4")
    }

    @Test("a tile in a grid says where it sits, a lone tile does not")
    func position() {
        #expect(MediaAccessibility.video(name: "b.mp4", duration: 5, position: (1, 3)) == "Video, b.mp4, 5 seconds, 2 of 3")
        #expect(MediaAccessibility.video(name: "b.mp4", duration: 5, position: (0, 1)) == "Video, b.mp4, 5 seconds")
    }

    @Test("a document card names kind, file, pages and size")
    func document() {
        let strip = DocumentStrip(name: "Q3 report.pdf", typeLabel: "PDF", kind: .pdf, pageCount: 12)
        #expect(strip.accessibilityLabel == "PDF document, Q3 report.pdf, 12 pages")
        #expect(MediaAccessibility.openHint == "Double tap to open")
        #expect(DocumentStrip.openHint == MediaAccessibility.openHint)
    }

    @Test("too-large and failed cards speak the file and the state")
    func states() {
        #expect(MediaAccessibility.tooLarge(kind: "Archive", name: "logs.zip", size: 300_000_000)
            == "Archive, logs.zip, \(MediaSize.label(300_000_000)), too large to preview")
        #expect(MediaAccessibility.tooLarge(kind: "Video", name: "huge.mp4", size: nil) == "Video, huge.mp4, too large to preview")
        #expect(MediaAccessibility.failed(kind: "File", name: "a.bin", reason: "The file isn't there") == "File, a.bin, The file isn't there")
    }

    @Test("the size ceiling line is the same for every kind except its verb")
    func ceilingLine() {
        #expect(MediaStateText.tooLarge(size: 5_000_000, playable: false) == "\(MediaSize.label(5_000_000)) · Too large to preview")
        #expect(MediaStateText.tooLarge(size: 5_000_000, playable: true) == "\(MediaSize.label(5_000_000)) · Too large to play here")
        #expect(MediaStateText.tooLarge(size: nil, playable: false) == "Too large to preview")
    }
}
