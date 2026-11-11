import Foundation
import Testing
@testable import PalDesign

private let clips = LoadingClips.all
private let cycle = LoadingClips.cycleDuration

private func canonicalFile(_ path: String = #filePath) -> URL {
    var url = URL(fileURLWithPath: path)
    for _ in 0..<7 { url.deleteLastPathComponent() }
    return url.appendingPathComponent("apps/shared/src/avatar-loading-clips.json")
}

private func sameAsFacing(_ pose: AvatarPose, tolerance: Double = 1e-9) -> Bool {
    allFields.allSatisfy { abs(pose[keyPath: $0] - AvatarPose.facing[keyPath: $0]) <= tolerance }
}

private func close(_ a: AvatarPose, _ b: AvatarPose) -> Bool {
    allFields.allSatisfy { abs(a[keyPath: $0] - b[keyPath: $0]) < 1e-6 }
}

private struct Vectors: Decodable {
    struct Vector: Decodable {
        let key: String
        let clips: [String]
    }

    let vectors: [Vector]
}

@Suite("Loading clips")
struct LoadingClipTests {
    @Test("twenty distinct clips, each between 1.2 and 3.6 seconds")
    func catalogue() {
        #expect(clips.count == 20)
        #expect(Set(clips.map(\.name)).count == 20)
        for clip in clips {
            #expect((1.2...3.6).contains(clip.duration), "\(clip.name) lasts \(clip.duration)")
        }
    }

    @Test("every clip starts and ends facing the viewer", arguments: clips.map(\.name))
    func facingAtBothEnds(name: String) throws {
        let clip = try #require(clips.first { $0.name == name })
        #expect(sameAsFacing(clip.track.pose(at: 0)))
        #expect(sameAsFacing(clip.track.pose(at: clip.duration)))
        #expect(clip.track.keys.first?.time == 0)
    }

    @Test("eyes only teleport while hidden and nothing else visibly jumps", arguments: clips.map(\.name))
    func noVisibleJumps(name: String) throws {
        let clip = try #require(clips.first { $0.name == name })
        for (a, b) in zip(clip.track.keys, clip.track.keys.dropFirst()) where a.time == b.time {
            #expect(eyesHidden(a.pose) && eyesHidden(b.pose), "\(name) teleports visible eyes at t=\(a.time)")
        }
        let times = samples(0...clip.duration)
        for (a, b) in zip(times, times.dropFirst()) {
            #expect(!visibleJump(clip.track.pose(at: a), clip.track.pose(at: b)), "\(name) jumps between t=\(a) and t=\(b)")
        }
    }

    @Test("poses stay inside the ranges the avatars were tuned for", arguments: clips.map(\.name))
    func ranges(name: String) throws {
        let clip = try #require(clips.first { $0.name == name })
        for key in clip.track.keys where !eyesHidden(key.pose) {
            let pose = key.pose
            #expect(abs(pose.eyeX) <= 0.42 && abs(pose.eyeY) <= 0.42, "\(name) looks too far at t=\(key.time)")
            #expect(abs(pose.bodyX) <= 0.06 && abs(pose.bodyY) <= 0.14)
            #expect((0.4...1.35).contains(pose.eyeScale) && (0...1).contains(pose.eyeOpen) && (0...1).contains(pose.eyeDot))
        }
    }

    @Test("the bundled clips are byte-identical to the shared file")
    func bundledMatchesShared() throws {
        let shared = try Data(contentsOf: canonicalFile())
        #expect(LoadingClips.bundledData() == shared)
    }
}

@Suite("Loading sequence")
struct LoadingSequenceTests {
    private let sequence = LoadingSequence(key: "alpha")

    @Test("hashing and shuffling follow the published algorithms")
    func primitives() {
        #expect(LoadingSequence.seed(for: "") == 0xcbf2_9ce4_8422_2325)
        #expect(LoadingSequence.seed(for: "a") == 0xaf63_dc4c_8601_ec8c)
        var generator = SplitMix64(seed: 0)
        #expect(generator.next() == 0xe220_a839_7b1d_cdaf)
    }

    @Test("every bag plays each clip exactly once")
    func bagsAreComplete() {
        for key in ["alpha", "chó pal bot", "", "Nova"] {
            let sequence = LoadingSequence(key: key)
            for index in 0..<60 {
                #expect(sequence.bag(index).sorted() == Array(0..<clips.count), "bag \(index) of \(key)")
            }
        }
    }

    @Test("no clip repeats back to back, across bag boundaries too")
    func noRepeats() {
        for key in (0..<40).map({ "bot-\($0)" }) {
            let order = LoadingSequence(key: key).clipIndices(first: 20 * 60)
            #expect(zip(order, order.dropFirst()).allSatisfy { $0 != $1 }, "repeat for \(key)")
        }
    }

    @Test("the sequence is deterministic per key and differs between keys")
    func perKey() {
        let keys = (0..<24).map { "bot-\($0)" }
        let orders = keys.map { LoadingSequence(key: $0).clipIndices(first: 20) }
        #expect(orders == keys.map { LoadingSequence(key: $0).clipIndices(first: 20) })
        #expect(Set(orders).count == keys.count)
    }

    @Test("it reproduces the shared vectors")
    func vectors() throws {
        let file = try JSONDecoder().decode(Vectors.self, from: LoadingClips.bundledData())
        #expect(file.vectors.count >= 3)
        for vector in file.vectors {
            let names = LoadingSequence(key: vector.key).clipIndices(first: 45).map { clips[$0].name }
            #expect(names == vector.clips, "vector for \"\(vector.key)\"")
        }
    }

    @Test("time walks the bag clip by clip")
    func walksBag() {
        var start = 0.0
        for index in sequence.bag(0) {
            let clip = clips[index]
            let inside = start + clip.duration / 2
            #expect(close(sequence.pose(at: inside), clip.track.pose(at: clip.duration / 2)), "\(clip.name)")
            start += clip.duration
        }
        let second = clips[sequence.bag(1)[0]]
        #expect(close(sequence.pose(at: cycle + second.duration / 2), second.track.pose(at: second.duration / 2)))
    }

    @Test("every clip and bag boundary joins seamlessly")
    func continuity() {
        let times = samples(0...(3 * cycle))
        var previous = sequence.pose(at: times[0])
        for t in times.dropFirst() {
            let current = sequence.pose(at: t)
            #expect(!visibleJump(previous, current), "visible jump at t=\(t)")
            previous = current
        }
        for index in 0..<3 {
            var boundary = Double(index) * cycle
            for clipIndex in sequence.bag(index) {
                #expect(sameAsFacing(sequence.pose(at: boundary), tolerance: 1e-6), "not facing at t=\(boundary)")
                boundary += clips[clipIndex].duration
            }
        }
    }

    @Test("loading starts facing at t=0 and tolerates negative time")
    func opens() {
        #expect(sameAsFacing(sequence.pose(at: 0)))
        #expect(sameAsFacing(sequence.pose(at: -3)))
    }
}

@Suite("Each loading session")
struct LoadingSessionTests {
    @Test("the same bot opens loading sessions with different clips")
    func sessionsVary() {
        let seed = LoadingSequence.seed(for: "chó pal bot")
        let openers = Set((0..<12).map { minute in
            let clock = AvatarMoodClock(
                mood: .work,
                since: Date(timeIntervalSince1970: 1_800_000_000 + Double(minute) * 61.7),
                blinkDelay: 0,
                loadingSeed: seed,
                reduceMotion: false
            )
            return LoadingSequence(seed: clock.sessionSeed).bag(0)[0]
        })
        #expect(openers.count >= 4)
    }
}
