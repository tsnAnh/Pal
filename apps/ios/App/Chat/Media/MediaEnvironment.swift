import PalChat
import SwiftUI

private struct MediaPreviewResolverKey: EnvironmentKey {
    static let defaultValue: MediaPreviewResolver? = nil
}

private struct MediaOpenerKey: EnvironmentKey {
    static let defaultValue: (@MainActor (MediaReference, String) -> Void)? = nil
}

private struct MediaRowIDKey: EnvironmentKey {
    static let defaultValue = ""
}

extension EnvironmentValues {
    var mediaPreviewResolver: MediaPreviewResolver? {
        get { self[MediaPreviewResolverKey.self] }
        set { self[MediaPreviewResolverKey.self] = newValue }
    }

    var mediaOpener: (@MainActor (MediaReference, String) -> Void)? {
        get { self[MediaOpenerKey.self] }
        set { self[MediaOpenerKey.self] = newValue }
    }

    var mediaRowID: String {
        get { self[MediaRowIDKey.self] }
        set { self[MediaRowIDKey.self] = newValue }
    }
}

struct ChatModelMediaSource: MediaAssetSource {
    let model: ChatModel

    func preview(_ reference: MediaReference) async throws -> MediaPreviewAnswer {
        guard let session = await model.session else { throw ChatError.notConnected }
        return try await session.mediaPreview(ref: reference.id)
    }

    func chunk(_ reference: MediaReference, offset: Int, length: Int) async throws -> MediaChunk {
        guard let session = await model.session else { throw ChatError.notConnected }
        return try await session.mediaChunk(ref: reference.id, offset: offset, length: length)
    }
}

extension ChatModel {
    var mediaResolver: MediaPreviewResolver {
        MediaPreviewResolver(source: ChatModelMediaSource(model: self))
    }
}

enum MediaFilePhase: Equatable {
    case idle
    case fetching(Double?)
    case ready(URL)
    case failed(message: String, retryable: Bool)
}

enum MediaFetch {
    static func file(
        _ media: MediaReference, from source: any MediaAssetSource, limit: Int?,
        progress: @escaping @MainActor (Double?) -> Void
    ) async -> MediaFilePhase {
        do {
            let url = try await MediaDownloads.download(media, from: source, limit: limit) { update in
                Task { @MainActor in progress(update.fraction) }
            }
            return .ready(url)
        } catch is CancellationError {
            return .idle
        } catch {
            let failure = MediaFailure(describing: error)
            return .failed(message: failure.message, retryable: failure.retryable)
        }
    }

    static func run(
        _ media: MediaReference, source: any MediaAssetSource, limit: Int?,
        progress: @escaping @MainActor (Double?) -> Void, completion: @escaping @MainActor (MediaFilePhase) -> Void
    ) -> Task<Void, Never> {
        Task { @MainActor in
            let phase = await file(media, from: source, limit: limit, progress: progress)
            completion(phase)
        }
    }
}
