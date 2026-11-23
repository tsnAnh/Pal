@testable import PalChat
import Foundation
import PalProtocol
import PalTransport

final class FakeMediaAssetSource: MediaAssetSource, @unchecked Sendable {
    typealias ChunkHook = @Sendable (_ call: Int) async throws -> Void

    private struct State {
        var preview: Result<MediaPreviewAnswer, any Error>
        var payload: Data
        var reportedTotal: Int?
        var chunkFailure: (any Error)?
        var hook: ChunkHook?
        var previewCalls = 0
        var chunkCalls = 0
    }

    private let lock = NSLock()
    private var state: State

    init(preview: Result<MediaPreviewAnswer, any Error>, payload: Data = Data(), reportedTotal: Int? = nil) {
        state = State(preview: preview, payload: payload, reportedTotal: reportedTotal)
    }

    convenience init(answer: MediaPreviewAnswer, payload: Data = Data(), reportedTotal: Int? = nil) {
        self.init(preview: .success(answer), payload: payload, reportedTotal: reportedTotal)
    }

    convenience init(failure: any Error, payload: Data = Data()) {
        self.init(preview: .failure(failure), payload: payload)
    }

    var previewCalls: Int { lock.withLock { state.previewCalls } }
    var chunkCalls: Int { lock.withLock { state.chunkCalls } }

    func setChunkFailure(_ failure: (any Error)?) {
        lock.withLock { state.chunkFailure = failure }
    }

    func setHook(_ hook: ChunkHook?) {
        lock.withLock { state.hook = hook }
    }

    func preview(_ reference: MediaReference) async throws -> MediaPreviewAnswer {
        let scripted = lock.withLock { () -> Result<MediaPreviewAnswer, any Error> in
            state.previewCalls += 1
            return state.preview
        }
        return try scripted.get()
    }

    func chunk(_ reference: MediaReference, offset: Int, length: Int) async throws -> MediaChunk {
        let snapshot = lock.withLock { () -> State in
            state.chunkCalls += 1
            return state
        }
        if let hook = snapshot.hook { try await hook(snapshot.chunkCalls) }
        if let failure = snapshot.chunkFailure { throw failure }
        let payload = snapshot.payload
        let start = min(max(offset, 0), payload.count)
        let end = min(start + max(length, 0), payload.count)
        return MediaChunk(
            data: payload.subdata(in: start..<end), offset: offset, total: snapshot.reportedTotal ?? payload.count
        )
    }
}

final class FakePosterGenerator: MediaPosterGenerator, @unchecked Sendable {
    struct Call: Sendable, Equatable {
        let url: URL
        let fileExisted: Bool
        let bytes: Data?
        let maxPixel: Int
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    private let outcome: Result<GeneratedPoster?, any Error>

    init(outcome: Result<GeneratedPoster?, any Error>) {
        self.outcome = outcome
    }

    convenience init(poster: GeneratedPoster?) {
        self.init(outcome: .success(poster))
    }

    var calls: [Call] { lock.withLock { recorded } }

    func poster(forFileAt url: URL, maxPixel: Int) async throws -> GeneratedPoster? {
        let call = Call(
            url: url, fileExisted: FileManager.default.fileExists(atPath: url.path),
            bytes: try? Data(contentsOf: url), maxPixel: maxPixel
        )
        lock.withLock { recorded.append(call) }
        return try outcome.get()
    }
}

final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [MediaTransferProgress] = []

    var values: [MediaTransferProgress] { lock.withLock { recorded } }

    func add(_ progress: MediaTransferProgress) {
        lock.withLock { recorded.append(progress) }
    }
}

enum MediaFixtures {
    static func reference(_ name: String = "clip.mp4", kind: MediaKind = .video, size: Int? = nil) -> MediaReference {
        MediaReference(id: "ref-\(name)", name: name, kind: kind, size: size)
    }

    static func rpc(_ code: Int) -> GatewayTransportError {
        .rpc(RPCError(code: code, message: "raw message"))
    }

    static func bareRPC(_ code: Int) -> RPCError {
        RPCError(code: code, message: "raw message")
    }

    static func payload(count: Int) -> Data {
        Data((0..<count).map { UInt8($0 % 251) })
    }

    static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "pal-media-test-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    static func withTemporaryRoot(_ body: (URL) async throws -> Void) async throws {
        let root = temporaryDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(root)
    }

    static func entries(in directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    }

    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}
