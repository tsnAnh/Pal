import Foundation

public struct GeneratedThumbnail: Sendable, Equatable {
    public let jpeg: Data
    public let pageCount: Int?
    public let width: Int
    public let height: Int

    public init(jpeg: Data, pageCount: Int?, width: Int, height: Int) {
        self.jpeg = jpeg
        self.pageCount = pageCount
        self.width = width
        self.height = height
    }
}

public protocol DocumentThumbnailGenerating: Sendable {
    func thumbnail(forFileAt url: URL, kind: DocumentKind, maxPixel: Int) async throws -> GeneratedThumbnail?
}

public actor DocumentThumbnailQueue {
    public static let shared = DocumentThumbnailQueue()

    private var busy = false
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, any Error>)] = []

    public init() {}

    public func run<T: Sendable>(_ work: @Sendable () async throws -> T) async throws -> T {
        try await acquire()
        defer { release() }
        return try await work()
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        guard busy else {
            busy = true
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append((id, continuation))
            }
        } onCancel: {
            Task { await self.abandon(id) }
        }
    }

    private func abandon(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func release() {
        guard !waiters.isEmpty else {
            busy = false
            return
        }
        waiters.removeFirst().continuation.resume()
    }
}

public struct DocumentPreviewResolver: Sendable {
    public let source: any MediaAssetSource
    public let cache: MediaPosterCache
    public let generator: any DocumentThumbnailGenerating
    public let queue: DocumentThumbnailQueue
    public let pixels: Int

    public init(
        source: any MediaAssetSource,
        cache: MediaPosterCache = .shared,
        generator: any DocumentThumbnailGenerating = SystemDocumentThumbnailGenerator(),
        queue: DocumentThumbnailQueue = .shared,
        pixels: Int = DocumentCardMetrics.thumbnailPixels
    ) {
        self.source = source
        self.cache = cache
        self.generator = generator
        self.queue = queue
        self.pixels = pixels
    }

    public func cached(_ reference: MediaReference) -> MediaPreview? {
        cache.cached(MediaPosterKey(id: reference.id, pixels: pixels))
    }

    public func resolve(_ reference: MediaReference, kind: DocumentKind) async throws -> MediaPreviewState {
        let key = MediaPosterKey(id: reference.id, pixels: pixels)
        if let hit = await cache.load(key) { return .ready(hit) }
        if let size = reference.size, !MediaLimits.allowsThumbnail(size: size) { return .tooLarge(size: size) }
        let outcome = try await queue.run { try await thumbnail(reference, kind: kind) }
        if case .ready(let preview, cacheable: true) = outcome { await cache.store(preview, for: key) }
        return outcome.state
    }

    private enum Outcome: Sendable {
        case ready(MediaPreview, cacheable: Bool)
        case other(MediaPreviewState)

        var state: MediaPreviewState {
            switch self {
            case .ready(let preview, _): .ready(preview)
            case .other(let state): state
            }
        }
    }

    private func thumbnail(_ reference: MediaReference, kind: DocumentKind) async throws -> Outcome {
        let file: URL
        do {
            file = try await MediaDownloads.download(reference, from: source, limit: MediaLimits.thumbnailSourceBytes)
        } catch is CancellationError {
            throw CancellationError()
        } catch MediaTransferError.tooLarge(let size) {
            return .other(.tooLarge(size: size))
        } catch {
            return .other(MediaPreviewResolver.state(for: error, reference: reference))
        }
        defer { MediaDownloads.remove(file) }
        let bytes = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? reference.size
        do {
            guard let generated = try await generator.thumbnail(forFileAt: file, kind: kind, maxPixel: pixels) else {
                return .ready(MediaPreview(poster: nil, size: bytes), cacheable: true)
            }
            let preview = MediaPreview(
                poster: generated.jpeg, size: bytes, width: generated.width, height: generated.height,
                pageCount: generated.pageCount
            )
            return .ready(preview, cacheable: true)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .ready(MediaPreview(poster: nil, size: bytes), cacheable: false)
        }
    }
}
