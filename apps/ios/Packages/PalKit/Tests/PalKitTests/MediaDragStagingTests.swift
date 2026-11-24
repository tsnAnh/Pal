@testable import PalChat
import Foundation
import Testing

private let clip = MediaFixtures.reference("clip.mp4", size: 250)

private func source(_ payload: Data = MediaFixtures.payload(count: 250)) -> FakeMediaAssetSource {
    FakeMediaAssetSource(answer: .unavailable(reason: "none", MediaMetadata()), payload: payload)
}

@Suite("Media drag staging")
struct MediaDragStagingTests {
    @Test("a staged file holds the downloaded bytes under the media's own name")
    func stagesFile() async throws {
        let payload = MediaFixtures.payload(count: 250)
        try await MediaFixtures.withTemporaryRoot { root in
            let staging = MediaDragStaging(root: root)
            let file = try await staging.stage(clip, from: source(payload), limit: nil)
            #expect(try Data(contentsOf: file) == payload)
            #expect(file.lastPathComponent == "clip.mp4")
            #expect(staging.stagedFiles == [file])
        }
    }

    @Test("releasing removes the file and its folder")
    func releaseRemoves() async throws {
        try await MediaFixtures.withTemporaryRoot { root in
            let staging = MediaDragStaging(root: root)
            let file = try await staging.stage(clip, from: source(), limit: nil)
            staging.release()
            #expect(!MediaFixtures.exists(file))
            #expect(MediaFixtures.entries(in: root).isEmpty)
            #expect(staging.stagedFiles.isEmpty)
        }
    }

    @Test("dragging the same media twice downloads it once")
    func reuses() async throws {
        let fake = source()
        try await MediaFixtures.withTemporaryRoot { root in
            let staging = MediaDragStaging(root: root)
            let first = try await staging.stage(clip, from: fake, limit: nil)
            let calls = fake.chunkCalls
            let second = try await staging.stage(clip, from: fake, limit: nil)
            #expect(first == second)
            #expect(fake.chunkCalls == calls)
        }
    }

    @Test("a download over the limit leaves nothing staged")
    func overLimit() async throws {
        let fake = FakeMediaAssetSource(
            answer: .unavailable(reason: "none", MediaMetadata()), payload: MediaFixtures.payload(count: 250), reportedTotal: 900
        )
        try await MediaFixtures.withTemporaryRoot { root in
            let staging = MediaDragStaging(root: root)
            await #expect(throws: MediaTransferError.tooLarge(size: 900)) {
                _ = try await staging.stage(clip, from: fake, limit: 500)
            }
            #expect(staging.stagedFiles.isEmpty)
            #expect(MediaFixtures.entries(in: root).isEmpty)
        }
    }

    @Test("a cancelled drag removes its partial download")
    func cancelled() async throws {
        let fake = source()
        fake.setHook { _ in try await Task.sleep(for: .seconds(30)) }
        try await MediaFixtures.withTemporaryRoot { root in
            let staging = MediaDragStaging(root: root)
            let task = Task { try await staging.stage(clip, from: fake, limit: nil) }
            while fake.chunkCalls == 0 { await Task.yield() }
            task.cancel()
            _ = await task.result
            #expect(staging.stagedFiles.isEmpty)
            #expect(MediaFixtures.entries(in: root).isEmpty)
        }
    }

    @Test("releasing while a download runs removes the file once it lands")
    func releaseWhileFetching() async throws {
        let fake = source()
        let gate = AsyncGate()
        fake.setHook { _ in await gate.wait() }
        try await MediaFixtures.withTemporaryRoot { root in
            let staging = MediaDragStaging(root: root)
            let task = Task { try await staging.stage(clip, from: fake, limit: nil) }
            while fake.chunkCalls == 0 { await Task.yield() }
            staging.release()
            await gate.open()
            _ = try await task.value
            #expect(staging.stagedFiles.isEmpty)
            #expect(MediaFixtures.entries(in: root).isEmpty)
        }
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}
