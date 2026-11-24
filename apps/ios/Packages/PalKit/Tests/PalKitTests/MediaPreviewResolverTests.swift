@testable import PalChat
import Foundation
import Testing

private struct ResolverRig {
    let directory: URL
    let source: FakeMediaAssetSource
    let cache: MediaPosterCache
    let resolver: MediaPreviewResolver

    init(source: FakeMediaAssetSource, generator: FakePosterGenerator? = nil) {
        let directory = MediaFixtures.temporaryDirectory()
        let cache = MediaPosterCache(directory: directory)
        self.directory = directory
        self.source = source
        self.cache = cache
        resolver = MediaPreviewResolver(source: source, cache: cache, generator: generator)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private let posterBytes = Data([1, 2, 3])
private let generatedPoster = GeneratedPoster(jpeg: Data([9, 9]), duration: 30, width: 640, height: 360)

private func unavailable(size: Int?, duration: TimeInterval? = nil) -> MediaPreviewAnswer {
    .unavailable(reason: "no_codec", MediaMetadata(size: size, duration: duration))
}

@Suite("Media preview resolver")
struct MediaPreviewResolverTests {
    @Test("a poster answer becomes a ready preview and is stored")
    func posterAnswer() async throws {
        let metadata = MediaMetadata(size: 1_000, duration: 12, width: 1920, height: 1080)
        let rig = ResolverRig(source: FakeMediaAssetSource(answer: .poster(posterBytes, metadata)))
        defer { rig.cleanUp() }
        let reference = MediaFixtures.reference()
        #expect(rig.resolver.cached(reference) == nil)
        let state = try await rig.resolver.resolve(reference)
        let expected = MediaPreview(poster: posterBytes, duration: 12, size: 1_000, width: 1920, height: 1080)
        #expect(state == .ready(expected))
        #expect(rig.resolver.cached(reference) == expected)
    }

    @Test("a second resolve is served from the cache")
    func secondResolveHitsCache() async throws {
        let rig = ResolverRig(source: FakeMediaAssetSource(answer: .poster(posterBytes, MediaMetadata(size: 1_000))))
        defer { rig.cleanUp() }
        let reference = MediaFixtures.reference()
        let first = try await rig.resolver.resolve(reference)
        let second = try await rig.resolver.resolve(reference)
        #expect(first == second)
        #expect(rig.source.previewCalls == 1)
        #expect(rig.resolver.cached(reference) != nil)
    }

    @Test("a fresh cache over the same folder is served from disk")
    func diskHit() async throws {
        let rig = ResolverRig(source: FakeMediaAssetSource(answer: .poster(posterBytes, MediaMetadata(size: 1_000, duration: 5))))
        defer { rig.cleanUp() }
        let reference = MediaFixtures.reference()
        let first = try await rig.resolver.resolve(reference)

        let reopened = MediaPosterCache(directory: rig.directory)
        let resolver = MediaPreviewResolver(source: rig.source, cache: reopened, generator: nil)
        #expect(resolver.cached(reference) == nil)
        let second = try await resolver.resolve(reference)
        #expect(second == first)
        #expect(rig.source.previewCalls == 1)
        #expect(resolver.cached(reference) != nil)
    }

    @Test("an unavailable video within the thumbnail limit is downloaded and posterised on device")
    func deviceFallback() async throws {
        let payload = MediaFixtures.payload(count: 10)
        let generator = FakePosterGenerator(poster: generatedPoster)
        let source = FakeMediaAssetSource(answer: unavailable(size: 5_000_000), payload: payload)
        let rig = ResolverRig(source: source, generator: generator)
        defer { rig.cleanUp() }
        let reference = MediaFixtures.reference("movie.mp4")
        let state = try await rig.resolver.resolve(reference)
        #expect(state == .ready(MediaPreview(poster: Data([9, 9]), duration: 30, size: 5_000_000, width: 640, height: 360)))
        #expect(source.chunkCalls == 1)
        let call = try #require(generator.calls.first)
        #expect(generator.calls.count == 1)
        #expect(call.fileExisted)
        #expect(call.bytes == payload)
        #expect(call.url.lastPathComponent == "movie.mp4")
        #expect(call.maxPixel == MediaPreviewResolver.posterPixels)
        _ = try await rig.resolver.resolve(reference)
        #expect(source.previewCalls == 1)
    }

    @Test("the downloaded copy is removed once the poster is generated")
    func downloadFolderRemoved() async throws {
        let generator = FakePosterGenerator(poster: generatedPoster)
        let source = FakeMediaAssetSource(answer: unavailable(size: 100), payload: MediaFixtures.payload(count: 10))
        let rig = ResolverRig(source: source, generator: generator)
        defer { rig.cleanUp() }
        _ = try await rig.resolver.resolve(MediaFixtures.reference())
        let call = try #require(generator.calls.first)
        #expect(call.fileExisted)
        #expect(!MediaFixtures.exists(call.url.deletingLastPathComponent()))
    }

    @Test("a video exactly at the thumbnail limit still downloads and one byte over does not")
    func thumbnailBoundary() async throws {
        let atLimit = FakeMediaAssetSource(answer: unavailable(size: 32_000_000), payload: MediaFixtures.payload(count: 4))
        let atLimitRig = ResolverRig(source: atLimit, generator: FakePosterGenerator(poster: generatedPoster))
        defer { atLimitRig.cleanUp() }
        let generated = try await atLimitRig.resolver.resolve(MediaFixtures.reference())
        #expect(atLimit.chunkCalls == 1)
        #expect(generated == .ready(MediaPreview(poster: Data([9, 9]), duration: 30, size: 32_000_000, width: 640, height: 360)))

        let over = FakeMediaAssetSource(answer: unavailable(size: 32_000_001), payload: MediaFixtures.payload(count: 4))
        let overRig = ResolverRig(source: over, generator: FakePosterGenerator(poster: generatedPoster))
        defer { overRig.cleanUp() }
        let bare = try await overRig.resolver.resolve(MediaFixtures.reference())
        #expect(over.chunkCalls == 0)
        #expect(bare == .ready(MediaPreview(poster: nil, size: 32_000_001)))
    }

    @Test("a busy gateway answer is shown but not cached, so the next view asks again")
    func busyAnswerIsNotCached() async throws {
        let answer = MediaPreviewAnswer.unavailable(reason: "busy", MediaMetadata(size: 50_000_000))
        let rig = ResolverRig(source: FakeMediaAssetSource(answer: answer, payload: MediaFixtures.payload(count: 4)))
        defer { rig.cleanUp() }
        let reference = MediaFixtures.reference()
        _ = try await rig.resolver.resolve(reference)
        _ = try await rig.resolver.resolve(reference)
        #expect(rig.source.previewCalls == 2)
        #expect(rig.resolver.cached(reference) == nil)
    }

    @Test("a large unavailable video is ready without a poster and is never downloaded")
    func largeVideoStaysBare() async throws {
        let generator = FakePosterGenerator(poster: generatedPoster)
        let source = FakeMediaAssetSource(answer: unavailable(size: 50_000_000, duration: 90), payload: MediaFixtures.payload(count: 4))
        let rig = ResolverRig(source: source, generator: generator)
        defer { rig.cleanUp() }
        let state = try await rig.resolver.resolve(MediaFixtures.reference())
        #expect(state == .ready(MediaPreview(poster: nil, duration: 90, size: 50_000_000)))
        #expect(source.chunkCalls == 0)
        #expect(generator.calls.isEmpty)
    }

    @Test("an unavailable audio file is ready without a poster and is never downloaded")
    func audioStaysBare() async throws {
        let generator = FakePosterGenerator(poster: generatedPoster)
        let source = FakeMediaAssetSource(answer: unavailable(size: 4_000, duration: 61), payload: MediaFixtures.payload(count: 4))
        let rig = ResolverRig(source: source, generator: generator)
        defer { rig.cleanUp() }
        let state = try await rig.resolver.resolve(MediaFixtures.reference("song.mp3", kind: .audio))
        #expect(state == .ready(MediaPreview(poster: nil, duration: 61, size: 4_000)))
        #expect(source.chunkCalls == 0)
        #expect(generator.calls.isEmpty)
    }

    @Test("metadata above the download limit reports too large")
    func metadataTooLarge() async throws {
        let big = FakeMediaAssetSource(answer: unavailable(size: 200_000_001))
        let bigRig = ResolverRig(source: big)
        defer { bigRig.cleanUp() }
        let bigState = try await bigRig.resolver.resolve(MediaFixtures.reference())
        #expect(bigState == .tooLarge(size: 200_000_001))

        let bigPoster = FakeMediaAssetSource(answer: .poster(posterBytes, MediaMetadata(size: 300_000_000)))
        let posterRig = ResolverRig(source: bigPoster)
        defer { posterRig.cleanUp() }
        let posterState = try await posterRig.resolver.resolve(MediaFixtures.reference())
        #expect(posterState == .tooLarge(size: 300_000_000))

        let exact = FakeMediaAssetSource(answer: unavailable(size: 200_000_000))
        let exactRig = ResolverRig(source: exact)
        defer { exactRig.cleanUp() }
        let exactState = try await exactRig.resolver.resolve(MediaFixtures.reference())
        #expect(exactState == .ready(MediaPreview(poster: nil, size: 200_000_000)))
    }

    @Test("a reference already known to be too large never reaches the source")
    func referenceTooLarge() async throws {
        let source = FakeMediaAssetSource(answer: .poster(posterBytes, MediaMetadata()))
        let rig = ResolverRig(source: source)
        defer { rig.cleanUp() }
        let state = try await rig.resolver.resolve(MediaFixtures.reference(size: 200_000_001))
        #expect(state == .tooLarge(size: 200_000_001))
        #expect(source.previewCalls == 0)
        #expect(source.chunkCalls == 0)
    }

    @Test("error 4152 means too large, whether bare or wrapped by the transport")
    func tooLargeError() async throws {
        let errors: [any Error] = [MediaFixtures.bareRPC(4152), MediaFixtures.rpc(4152)]
        for error in errors {
            let rig = ResolverRig(source: FakeMediaAssetSource(failure: error))
            defer { rig.cleanUp() }
            let state = try await rig.resolver.resolve(MediaFixtures.reference(size: 1_000))
            #expect(state == .tooLarge(size: 1_000))
        }
    }

    @Test("an unreachable bot is a retryable failure and a missing file is not")
    func failures() async throws {
        let unreachable = ResolverRig(source: FakeMediaAssetSource(failure: URLError(.notConnectedToInternet)))
        defer { unreachable.cleanUp() }
        let unreachableState = try await unreachable.resolver.resolve(MediaFixtures.reference())
        #expect(unreachableState == .failed(reason: FileLoadFailure(cause: .unreachable).message, retryable: true))

        let missing = ResolverRig(source: FakeMediaAssetSource(failure: MediaFixtures.rpc(4151)))
        defer { missing.cleanUp() }
        let missingState = try await missing.resolver.resolve(MediaFixtures.reference())
        #expect(missingState == .failed(reason: FileLoadFailure(cause: .notFound).message, retryable: false))

        let broken = ResolverRig(source: FakeMediaAssetSource(failure: MediaFixtures.rpc(5000)))
        defer { broken.cleanUp() }
        let brokenState = try await broken.resolver.resolve(MediaFixtures.reference())
        #expect(brokenState == .failed(reason: FileLoadFailure(cause: .unknown(code: 5000)).message, retryable: true))
    }

    @Test("a failed answer is not cached")
    func failureNotCached() async throws {
        let source = FakeMediaAssetSource(failure: URLError(.notConnectedToInternet))
        let rig = ResolverRig(source: source)
        defer { rig.cleanUp() }
        _ = try await rig.resolver.resolve(MediaFixtures.reference())
        _ = try await rig.resolver.resolve(MediaFixtures.reference())
        #expect(source.previewCalls == 2)
    }

    @Test("cancellation propagates instead of becoming a failure")
    func cancellationPropagates() async throws {
        let rig = ResolverRig(source: FakeMediaAssetSource(failure: CancellationError()))
        defer { rig.cleanUp() }
        await #expect(throws: CancellationError.self) {
            try await rig.resolver.resolve(MediaFixtures.reference())
        }

        let source = FakeMediaAssetSource(answer: unavailable(size: 100), payload: MediaFixtures.payload(count: 4))
        source.setChunkFailure(CancellationError())
        let fallback = ResolverRig(source: source, generator: FakePosterGenerator(poster: generatedPoster))
        defer { fallback.cleanUp() }
        await #expect(throws: CancellationError.self) {
            try await fallback.resolver.resolve(MediaFixtures.reference())
        }
    }

    @Test("a failed device download gives a bare preview that is not cached")
    func downloadFailureNotCached() async throws {
        let generator = FakePosterGenerator(poster: generatedPoster)
        let source = FakeMediaAssetSource(answer: unavailable(size: 100), payload: MediaFixtures.payload(count: 4))
        source.setChunkFailure(URLError(.networkConnectionLost))
        let rig = ResolverRig(source: source, generator: generator)
        defer { rig.cleanUp() }
        let reference = MediaFixtures.reference()
        let first = try await rig.resolver.resolve(reference)
        #expect(first == .ready(MediaPreview(poster: nil, size: 100)))
        #expect(rig.resolver.cached(reference) == nil)
        #expect(generator.calls.isEmpty)
        _ = try await rig.resolver.resolve(reference)
        #expect(source.previewCalls == 2)
    }

    @Test("a generator that finds no frame is cached as a bare preview")
    func noFrameCached() async throws {
        let generator = FakePosterGenerator(poster: nil)
        let source = FakeMediaAssetSource(answer: unavailable(size: 100), payload: MediaFixtures.payload(count: 4))
        let rig = ResolverRig(source: source, generator: generator)
        defer { rig.cleanUp() }
        let reference = MediaFixtures.reference()
        let first = try await rig.resolver.resolve(reference)
        #expect(first == .ready(MediaPreview(poster: nil, size: 100)))
        #expect(rig.resolver.cached(reference) != nil)
        _ = try await rig.resolver.resolve(reference)
        #expect(source.previewCalls == 1)
        #expect(generator.calls.count == 1)
    }
}

@Suite("Media poster cache")
struct MediaPosterCacheTests {
    private let preview = MediaPreview(poster: Data([7, 7]), duration: 2, size: 9, width: 16, height: 9)

    @Test("unsafe characters in an id never reach the file name")
    func stemSanitised() {
        #expect(MediaPosterKey(id: "a/b c:d.e", pixels: 660).stem == "a_b_c_d_e-660")
        #expect(MediaPosterKey(id: "keep-This_1", pixels: 1).stem == "keep-This_1-1")
        let hostile = MediaPosterKey(id: "../../etc/passwd", pixels: 660).stem
        #expect(!hostile.contains("/"))
        #expect(!hostile.contains("."))
        #expect(hostile.hasSuffix("-660"))
    }

    @Test("the same media at different pixel sizes are different entries")
    func pixelsSeparateEntries() async {
        let directory = MediaFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = MediaPosterCache(directory: directory)
        let small = MediaPosterKey(id: "m", pixels: 300)
        let large = MediaPosterKey(id: "m", pixels: 600)
        await cache.store(preview, for: small)
        #expect(cache.cached(small) == preview)
        #expect(cache.cached(large) == nil)
        let missing = await cache.load(large)
        #expect(missing == nil)
    }

    @Test("a preview without a poster survives a round trip through disk")
    func barePreviewRoundTrip() async {
        let directory = MediaFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = MediaPosterKey(id: "audio", pixels: 660)
        let bare = MediaPreview(poster: nil, duration: 61, size: 4_000)
        await MediaPosterCache(directory: directory).store(bare, for: key)
        let loaded = await MediaPosterCache(directory: directory).load(key)
        #expect(loaded == bare)
    }

    @Test("a preview with a poster survives a round trip through disk")
    func posterRoundTrip() async {
        let directory = MediaFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = MediaPosterKey(id: "video", pixels: 660)
        await MediaPosterCache(directory: directory).store(preview, for: key)
        let loaded = await MediaPosterCache(directory: directory).load(key)
        #expect(loaded == preview)
    }

    @Test("removing everything clears memory and disk")
    func removeAll() async {
        let directory = MediaFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = MediaPosterCache(directory: directory)
        let key = MediaPosterKey(id: "m", pixels: 660)
        await cache.store(preview, for: key)
        #expect(MediaFixtures.exists(directory))
        await cache.removeAll()
        #expect(cache.cached(key) == nil)
        #expect(!MediaFixtures.exists(directory))
        let afterClear = await cache.load(key)
        #expect(afterClear == nil)
        let reopened = await MediaPosterCache(directory: directory).load(key)
        #expect(reopened == nil)
    }
}

@Suite("Media poster cache cap")
struct MediaPosterCacheCapTests {
    private func store(_ id: String, bytes: Int, age: TimeInterval, in directory: URL, cache: MediaPosterCache) async throws {
        let key = MediaPosterKey(id: id, pixels: 660)
        await cache.store(MediaPreview(poster: Data(count: bytes), duration: 1), for: key)
        let date = Date().addingTimeInterval(-age)
        for entry in MediaFixtures.entries(in: directory) where entry.lastPathComponent.hasPrefix(key.stem) {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: entry.path)
        }
    }

    @Test("pruning drops the oldest entries first and keeps both files of a survivor")
    func oldestGoFirst() async throws {
        let directory = MediaFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = MediaPosterCache(directory: directory, maxBytes: 1_000_000)
        try await store("old", bytes: 400, age: 300, in: directory, cache: cache)
        try await store("mid", bytes: 400, age: 200, in: directory, cache: cache)
        try await store("new", bytes: 400, age: 100, in: directory, cache: cache)
        MediaPosterCache.prune(in: directory, maxBytes: 1_200)
        let names = Set(MediaFixtures.entries(in: directory).map(\.lastPathComponent))
        #expect(!names.contains { $0.hasPrefix("old-") })
        #expect(names.contains { $0.hasPrefix("mid-") && $0.hasSuffix(".jpg") })
        #expect(names.contains { $0.hasPrefix("mid-") && $0.hasSuffix(".json") })
        #expect(names.contains { $0.hasPrefix("new-") && $0.hasSuffix(".jpg") })
    }

    @Test("storing past the cap keeps the folder under it")
    func storeEnforcesCap() async throws {
        let directory = MediaFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = MediaPosterCache(directory: directory, maxBytes: 3_000)
        for index in 0..<6 { try await store("m\(index)", bytes: 1_000, age: Double(600 - index * 100), in: directory, cache: cache) }
        let total = MediaFixtures.entries(in: directory).reduce(0) {
            $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        #expect(total <= 3_000)
        #expect(!MediaFixtures.entries(in: directory).isEmpty)
    }

    @Test("a folder under the cap is left alone")
    func underCap() async throws {
        let directory = MediaFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = MediaPosterCache(directory: directory)
        try await store("a", bytes: 100, age: 10, in: directory, cache: cache)
        let before = MediaFixtures.entries(in: directory).count
        MediaPosterCache.prune(in: directory, maxBytes: 1_000_000)
        #expect(MediaFixtures.entries(in: directory).count == before)
    }
}
