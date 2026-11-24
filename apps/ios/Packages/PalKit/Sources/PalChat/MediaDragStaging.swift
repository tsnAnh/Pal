import Foundation

public final class MediaDragStaging: @unchecked Sendable {
    private struct State {
        var files: [String: URL] = [:]
        var inFlight = 0
        var releaseWhenIdle = false
    }

    private let lock = NSLock()
    private var state = State()
    private let root: URL

    public init(root: URL = MediaDownloads.directory) {
        self.root = root
    }

    public var stagedFiles: [URL] { lock.withLock { Array(state.files.values) } }

    public func stage(
        _ reference: MediaReference,
        from source: any MediaAssetSource,
        limit: Int?,
        progress: @Sendable (MediaTransferProgress) -> Void = { _ in }
    ) async throws -> URL {
        let kept: URL? = lock.withLock {
            state.releaseWhenIdle = false
            guard let file = state.files[reference.id], FileManager.default.fileExists(atPath: file.path) else {
                state.inFlight += 1
                return nil
            }
            return file
        }
        if let kept { return kept }
        do {
            let file = try await MediaDownloads.download(reference, from: source, limit: limit, root: root, progress: progress)
            finish(reference.id, file: file)
            return file
        } catch {
            finish(reference.id, file: nil)
            throw error
        }
    }

    public func release() {
        let removed: [URL] = lock.withLock {
            guard state.inFlight == 0 else {
                state.releaseWhenIdle = true
                return []
            }
            return takeFiles()
        }
        removed.forEach(MediaDownloads.remove)
    }

    private func finish(_ id: String, file: URL?) {
        let removed: [URL] = lock.withLock {
            state.inFlight -= 1
            if let file { state.files[id] = file }
            guard state.releaseWhenIdle, state.inFlight == 0 else { return [] }
            return takeFiles()
        }
        removed.forEach(MediaDownloads.remove)
    }

    private func takeFiles() -> [URL] {
        let files = Array(state.files.values)
        state.files = [:]
        state.releaseWhenIdle = false
        return files
    }
}
