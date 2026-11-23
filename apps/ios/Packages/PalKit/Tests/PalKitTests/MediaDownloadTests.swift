@testable import PalChat
import Foundation
import Testing

private let clip = MediaFixtures.reference("clip.mp4", size: 250)

private func idleSource(payload: Data, reportedTotal: Int? = nil) -> FakeMediaAssetSource {
    FakeMediaAssetSource(answer: .unavailable(reason: "none", MediaMetadata()), payload: payload, reportedTotal: reportedTotal)
}

private func makeFolder(in root: URL, named name: String, age: TimeInterval, now: Date) throws -> URL {
    let folder = root.appending(path: name, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data([1]).write(to: folder.appending(path: "clip.mp4", directoryHint: .notDirectory))
    try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: folder.path)
    return folder
}

@Suite("Media downloads")
struct MediaDownloadTests {
    @Test("every chunk is assembled into a playable file that keeps its extension")
    func assemblesFile() async throws {
        let payload = MediaFixtures.payload(count: 250)
        let source = idleSource(payload: payload)
        try await MediaFixtures.withTemporaryRoot { root in
            let file = try await MediaDownloads.download(clip, from: source, limit: nil, root: root, chunkBytes: 64)
            let bytes = try Data(contentsOf: file)
            #expect(bytes == payload)
            #expect(file.lastPathComponent == "clip.mp4")
            #expect(file.pathExtension == "mp4")
            #expect(source.chunkCalls == 4)
        }
    }

    @Test("progress grows with every chunk and ends at the total")
    func progressMonotonic() async throws {
        let source = idleSource(payload: MediaFixtures.payload(count: 250))
        let log = ProgressLog()
        try await MediaFixtures.withTemporaryRoot { root in
            _ = try await MediaDownloads.download(
                clip, from: source, limit: nil, root: root, chunkBytes: 64, progress: { log.add($0) }
            )
        }
        let received = log.values.map(\.received)
        #expect(received == [64, 128, 192, 250])
        #expect(log.values.allSatisfy { $0.total == 250 })
        #expect(log.values.last?.fraction == 1)
        #expect(log.values.first?.fraction == 64.0 / 250.0)
    }

    @Test("a file above the limit throws too large and leaves nothing behind")
    func limitExceeded() async throws {
        let source = idleSource(payload: MediaFixtures.payload(count: 250))
        try await MediaFixtures.withTemporaryRoot { root in
            await #expect(throws: MediaTransferError.tooLarge(size: 250)) {
                try await MediaDownloads.download(clip, from: source, limit: 100, root: root, chunkBytes: 64)
            }
            #expect(MediaFixtures.entries(in: root).isEmpty)
        }
    }

    @Test("a file exactly at the limit downloads")
    func limitInclusive() async throws {
        let source = idleSource(payload: MediaFixtures.payload(count: 100))
        try await MediaFixtures.withTemporaryRoot { root in
            let file = try await MediaDownloads.download(clip, from: source, limit: 100, root: root, chunkBytes: 64)
            let bytes = try Data(contentsOf: file)
            #expect(bytes.count == 100)
        }
    }

    @Test("a source that stops short of the total throws truncated and leaves nothing behind")
    func truncated() async throws {
        let source = idleSource(payload: MediaFixtures.payload(count: 100), reportedTotal: 250)
        try await MediaFixtures.withTemporaryRoot { root in
            await #expect(throws: MediaTransferError.truncated) {
                try await MediaDownloads.download(clip, from: source, limit: nil, root: root, chunkBytes: 64)
            }
            #expect(MediaFixtures.entries(in: root).isEmpty)
        }
    }

    @Test("a failing chunk surfaces its error and leaves nothing behind")
    func chunkFailure() async throws {
        let source = idleSource(payload: MediaFixtures.payload(count: 250))
        source.setChunkFailure(URLError(.networkConnectionLost))
        try await MediaFixtures.withTemporaryRoot { root in
            await #expect(throws: URLError.self) {
                try await MediaDownloads.download(clip, from: source, limit: nil, root: root, chunkBytes: 64)
            }
            #expect(MediaFixtures.entries(in: root).isEmpty)
        }
    }

    @Test("cancelling mid-download throws cancellation and leaves nothing behind")
    func cancelled() async throws {
        let source = idleSource(payload: MediaFixtures.payload(count: 10))
        source.setHook { call in
            if call == 2 { withUnsafeCurrentTask { task in if let task { task.cancel() } } }
        }
        try await MediaFixtures.withTemporaryRoot { root in
            let task = Task { try await MediaDownloads.download(clip, from: source, limit: nil, root: root, chunkBytes: 2) }
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(MediaFixtures.entries(in: root).isEmpty)
        }
    }

    @Test("removing a download deletes its folder and keeps the root")
    func removeDeletesFolder() async throws {
        let source = idleSource(payload: MediaFixtures.payload(count: 10))
        try await MediaFixtures.withTemporaryRoot { root in
            let file = try await MediaDownloads.download(clip, from: source, limit: nil, root: root)
            #expect(MediaFixtures.exists(file))
            MediaDownloads.remove(file)
            #expect(!MediaFixtures.exists(file))
            #expect(!MediaFixtures.exists(file.deletingLastPathComponent()))
            #expect(MediaFixtures.exists(root))
        }
    }

    @Test("a hostile file name cannot escape the download root")
    func hostileNameStaysInside() async throws {
        let hostile = MediaFixtures.reference("../../escape.mp4")
        let source = idleSource(payload: MediaFixtures.payload(count: 10))
        try await MediaFixtures.withTemporaryRoot { root in
            let file = try await MediaDownloads.download(hostile, from: source, limit: nil, root: root)
            #expect(file.lastPathComponent == "escape.mp4")
            let parent = file.deletingLastPathComponent().deletingLastPathComponent()
            #expect(parent.standardizedFileURL.path == root.standardizedFileURL.path)
        }
    }

    @Test("file names lose separators and control characters and never end up empty")
    func safeFileName() {
        #expect(MediaDownloads.safeFileName("clip.mp4") == "clip.mp4")
        #expect(MediaDownloads.safeFileName("a/b/c.mp4") == "c.mp4")
        #expect(MediaDownloads.safeFileName("../../etc/passwd") == "passwd")
        #expect(MediaDownloads.safeFileName("a\\b.mp4") == "ab.mp4")
        #expect(MediaDownloads.safeFileName("bad:name\u{01}\u{1F}.mp4") == "badname.mp4")
        #expect(MediaDownloads.safeFileName("  spaced.mp4  ") == "spaced.mp4")
        for empty in ["", "   ", "..", ".", "/", "\u{01}"] {
            #expect(MediaDownloads.safeFileName(empty) == "media", "\(empty.debugDescription)")
        }
    }

    @Test("sweeping removes folders older than a day and keeps fresh ones")
    func sweepStale() async throws {
        let now = Date()
        try await MediaFixtures.withTemporaryRoot { root in
            let old = try makeFolder(in: root, named: "old", age: MediaDownloads.staleAfter + 3_600, now: now)
            let fresh = try makeFolder(in: root, named: "fresh", age: MediaDownloads.staleAfter - 3_600, now: now)
            let justMade = try makeFolder(in: root, named: "justMade", age: 0, now: now)
            MediaDownloads.sweepStale(in: root, now: now)
            #expect(!MediaFixtures.exists(old))
            #expect(MediaFixtures.exists(fresh))
            #expect(MediaFixtures.exists(justMade))
        }
    }

    @Test("sweeping a root that does not exist is harmless")
    func sweepMissingRoot() {
        MediaDownloads.sweepStale(in: MediaFixtures.temporaryDirectory())
    }
}

@Suite("Media wire payload")
struct MediaWirePayloadTests {
    private func decode(_ json: String) throws -> LibraryMediaPayload {
        try JSONDecoder().decode(LibraryMediaPayload.self, from: Data(json.utf8))
    }

    @Test("a poster answer decodes its snake case keys")
    func posterAnswer() throws {
        let wire = try decode("""
        {"kind":"video","mime":"video/mp4","size":1234,"total":1234,"duration_seconds":12.5,\
        "width":1920,"height":1080,"data_base64":"AQID"}
        """)
        #expect(wire.kind == "video")
        #expect(wire.mime == "video/mp4")
        #expect(wire.size == 1234)
        #expect(wire.durationSeconds == 12.5)
        #expect(wire.width == 1920)
        #expect(wire.height == 1080)
        #expect(wire.previewUnavailable == nil)
        #expect(wire.dataBase64.flatMap { Data(base64Encoded: $0) } == Data([1, 2, 3]))
    }

    @Test("a preview unavailable answer carries the reason and no bytes")
    func unavailableAnswer() throws {
        let wire = try decode(#"{"kind":"video","size":99,"preview_unavailable":"no_codec"}"#)
        #expect(wire.previewUnavailable == "no_codec")
        #expect(wire.dataBase64 == nil)
        #expect(wire.size == 99)
        #expect(wire.durationSeconds == nil)
    }

    @Test("a chunk answer decodes its offset and total")
    func chunkAnswer() throws {
        let wire = try decode(#"{"data_base64":"AQID","total":10,"offset":4}"#)
        #expect(wire.total == 10)
        #expect(wire.offset == 4)
        #expect(wire.size == nil)
        #expect(wire.dataBase64.flatMap { Data(base64Encoded: $0) } == Data([1, 2, 3]))
    }

    @Test("unknown keys are ignored")
    func unknownKeys() throws {
        let wire = try decode(#"{"total":5,"future_field":{"nested":true}}"#)
        #expect(wire.total == 5)
    }
}
