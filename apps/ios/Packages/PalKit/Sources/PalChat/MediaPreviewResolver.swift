import Foundation

public struct MediaPreviewResolver: Sendable {
    public static let posterPixels = Int(MediaTileMetrics.single * 3)

    public let source: any MediaAssetSource
    public let cache: MediaPosterCache
    public let generator: (any MediaPosterGenerator)?
    public let pixels: Int

    public init(
        source: any MediaAssetSource,
        cache: MediaPosterCache = .shared,
        generator: (any MediaPosterGenerator)? = AVMediaPosterGenerator(),
        pixels: Int = MediaPreviewResolver.posterPixels
    ) {
        self.source = source
        self.cache = cache
        self.generator = generator
        self.pixels = pixels
    }

    public func cached(_ reference: MediaReference) -> MediaPreview? {
        cache.cached(MediaPosterKey(id: reference.id, pixels: pixels))
    }

    public func resolve(_ reference: MediaReference) async throws -> MediaPreviewState {
        let key = MediaPosterKey(id: reference.id, pixels: pixels)
        if let hit = await cache.load(key) { return .ready(hit) }
        if let size = reference.size, !MediaLimits.allowsDownload(size: size) { return .tooLarge(size: size) }
        let answer: MediaPreviewAnswer
        do {
            answer = try await source.preview(reference)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return Self.state(for: error, reference: reference)
        }
        switch answer {
        case .poster(let poster, let metadata):
            if let size = metadata.size, !MediaLimits.allowsDownload(size: size) { return .tooLarge(size: size) }
            return await remember(MediaPreview(poster: poster, metadata: metadata), key: key)
        case .unavailable(_, let metadata):
            if let size = metadata.size, !MediaLimits.allowsDownload(size: size) { return .tooLarge(size: size) }
            let fallback = try await devicePreview(reference, metadata: metadata)
            guard fallback.cacheable else { return .ready(fallback.preview) }
            return await remember(fallback.preview, key: key)
        }
    }

    static func state(for error: Error, reference: MediaReference) -> MediaPreviewState {
        if ImageLoadFailure.rpcCode(of: error) == 4152 { return .tooLarge(size: reference.size) }
        let failure = MediaFailure(describing: error)
        return .failed(reason: failure.message, retryable: failure.retryable)
    }

    private func remember(_ preview: MediaPreview, key: MediaPosterKey) async -> MediaPreviewState {
        await cache.store(preview, for: key)
        return .ready(preview)
    }

    private func devicePreview(_ reference: MediaReference, metadata: MediaMetadata) async throws -> (preview: MediaPreview, cacheable: Bool) {
        let bare = MediaPreview(poster: nil, metadata: metadata)
        guard reference.kind == .video, let generator, metadata.size.map(MediaLimits.allowsThumbnail(size:)) ?? true else {
            return (bare, true)
        }
        let file: URL
        do {
            file = try await MediaDownloads.download(reference, from: source, limit: MediaLimits.thumbnailSourceBytes)
        } catch is CancellationError {
            throw CancellationError()
        } catch MediaTransferError.tooLarge {
            return (bare, true)
        } catch {
            return (bare, false)
        }
        defer { MediaDownloads.remove(file) }
        let generated: GeneratedPoster?
        do {
            generated = try await generator.poster(forFileAt: file, maxPixel: pixels)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return (bare, true)
        }
        guard let generated else { return (bare, true) }
        let preview = MediaPreview(
            poster: generated.jpeg, duration: metadata.duration ?? generated.duration, size: metadata.size,
            width: metadata.width ?? generated.width, height: metadata.height ?? generated.height
        )
        return (preview, true)
    }
}
