import Foundation
import Testing
@testable import PalDesign

private let solidClips = SolidClips.all
private let flatClips = LoadingClips.played
private let turningFields: [String: Set<String>] = [
    "spin-around": ["yaw"], "peekaboo": ["yaw"], "front-flip": ["pitch"], "roll-over": ["bodyRotation"],
    "dot-chase": ["pairSpin"], "dizzy-eyes": ["eyeRoll"],
]

private func wrapped(_ degrees: Double) -> Double {
    let turned = degrees.truncatingRemainder(dividingBy: 360)
    return abs(turned) > 180 ? turned - 360 * (turned < 0 ? -1 : 1) : turned
}

private func onFacing(_ pose: AvatarPose) -> Bool {
    let angles: [WritableKeyPath<AvatarPose, Double>] = [\.yaw, \.pitch, \.bodyRotation, \.pairSpin, \.eyeRoll]
    let plain = AvatarPose.geometry + AvatarPose.appearance
    let angleKeys = Set(angles.map { $0 as AnyKeyPath })
    let flat = plain.allSatisfy { key in
        angleKeys.contains(key as AnyKeyPath) || abs(pose[keyPath: key] - AvatarPose.facing[keyPath: key]) < 1e-9
    }
    return flat && angles.allSatisfy { abs(wrapped(pose[keyPath: $0])) < 1e-9 }
}

private func close(_ a: AvatarPose, _ b: AvatarPose) -> Bool {
    let angles: Set<AnyKeyPath> = [\AvatarPose.yaw, \AvatarPose.pitch, \AvatarPose.bodyRotation, \AvatarPose.pairSpin, \AvatarPose.eyeRoll]
    return allFields.allSatisfy { key in
        let difference = a[keyPath: key] - b[keyPath: key]
        return abs(angles.contains(key as AnyKeyPath) ? wrapped(difference) : difference) < 1e-6
    }
}

private func angle(_ pose: AvatarPose, _ field: String) -> Double {
    switch field {
    case "yaw": pose.yaw
    case "pitch": pose.pitch
    case "bodyRotation": pose.bodyRotation
    case "pairSpin": pose.pairSpin
    default: pose.eyeRoll
    }
}

@Suite("3D loading clips")
struct SolidClipTests {
    @Test("fourteen distinct clips with names the 2D set does not use")
    func catalogue() {
        #expect(solidClips.count == 14)
        #expect(Set(solidClips.map(\.name)).count == 14)
        #expect(Set(solidClips.map(\.name)).isDisjoint(with: Set(flatClips.map(\.name))))
        for clip in solidClips { #expect((1.5...4.2).contains(clip.duration), "\(clip.name) lasts \(clip.duration)") }
    }

    @Test("every clip starts and ends exactly facing the viewer", arguments: solidClips.map(\.name))
    func facingAtBothEnds(name: String) throws {
        let clip = try #require(solidClips.first { $0.name == name })
        #expect(onFacing(clip.pose(at: 0)), "\(name) start \(clip.pose(at: 0))")
        #expect(onFacing(clip.pose(at: clip.duration)), "\(name) end \(clip.pose(at: clip.duration))")
        #expect(onFacing(clip.pose(at: -1)) && onFacing(clip.pose(at: clip.duration + 1)))
    }

    @Test("poses stay inside the ranges the solids were tuned for", arguments: solidClips.map(\.name))
    func ranges(name: String) throws {
        let clip = try #require(solidClips.first { $0.name == name })
        let turns = turningFields[name] ?? []
        for t in samples(0...clip.duration, step: 1.0 / 60) {
            let pose = clip.pose(at: t)
            #expect(pose.front == 1 && pose.eyeX == 0 && pose.eyeY == 0)
            #expect((0.4...1.4).contains(pose.eyeScale) && (0.7...1.15).contains(pose.eyeSpread), "\(name) eyes at \(t)")
            #expect((0...1).contains(pose.eyeOpen) && (0...1).contains(pose.eyeDot) && (0...1).contains(pose.eyeHappy))
            #expect(abs(pose.bodyX) <= 0.08 && pose.bodyY >= -0.11 && pose.bodyY <= 0.03, "\(name) travels at \(t)")
            #expect((0.82...1.16).contains(pose.bodyScaleX) && (0.82...1.12).contains(pose.bodyScaleY), "\(name) squashes at \(t)")
            #expect(pose.opacity == 1 && pose.dots == .zero)
            for field in ["yaw", "pitch", "bodyRotation", "pairSpin", "eyeRoll"] where !turns.contains(field) {
                let limit: Double = field == "yaw" && name == "peekaboo" ? 181 : (field == "yaw" || field == "pitch" ? 40 : 12)
                #expect(abs(angle(pose, field)) <= limit, "\(name) \(field) \(angle(pose, field)) at \(t)")
            }
        }
    }

    @Test("the body scale, travel and eye size never jump between frames", arguments: solidClips.map(\.name))
    func smooth(name: String) throws {
        let clip = try #require(solidClips.first { $0.name == name })
        let limits: [(WritableKeyPath<AvatarPose, Double>, Double)] = [
            (\.bodyX, 0.02), (\.bodyY, 0.03), (\.bodyScaleX, 0.05), (\.bodyScaleY, 0.05), (\.eyeScale, 0.05), (\.eyeSpread, 0.05),
        ]
        let times = samples(0...clip.duration, step: 1.0 / 120)
        for (a, b) in zip(times, times.dropFirst()) {
            for (key, limit) in limits {
                #expect(abs(clip.pose(at: a)[keyPath: key] - clip.pose(at: b)[keyPath: key]) <= limit, "\(name) jumps at \(a)")
            }
        }
    }

    @Test("whole-turn clips really turn the whole way round and land where they began")
    func wholeTurns() throws {
        for (name, fields) in turningFields where ["spin-around", "front-flip", "roll-over"].contains(name) {
            let clip = try #require(solidClips.first { $0.name == name })
            let field = try #require(fields.first)
            let peak = samples(0...clip.duration, step: 1.0 / 60).map { abs(angle(clip.pose(at: $0), field)) }.max() ?? 0
            #expect(peak > 340, "\(name) turns only \(peak)")
        }
    }

    @Test("each clip is visibly different from facing")
    func clipsMove() {
        for clip in solidClips {
            let moved = samples(0...clip.duration, step: 1.0 / 30).contains { !onFacing(clip.pose(at: $0)) }
            #expect(moved, "\(clip.name) never moves")
        }
    }

    @Test("every clip resolves to a solid pose that stays finite", arguments: solidClips.map(\.name))
    func resolvesFinite(name: String) throws {
        let clip = try #require(solidClips.first { $0.name == name })
        for t in samples(0...clip.duration, step: 1.0 / 30) {
            let pose = SolidPose.resolve(pose: clip.pose(at: t), look: .zero, restTilt: -14, reduceMotion: false)
            let numbers = [pose.yaw, pose.pitch, pose.roll, pose.eyeRoll, pose.pairSpin, pose.eyeScale, pose.eyeSpread, pose.bodyY]
            #expect(numbers.allSatisfy { $0.isFinite })
        }
    }
}

@Suite("Loading sequence with 3D clips")
struct SolidSequenceTests {
    private let key = "chó pal bot"

    private func superCycle(_ key: String, _ index: Int = 0) -> [LoadingClip] {
        LoadingSequence(key: key).clips(inSuperCycle: index)
    }

    @Test("a 3D clip follows every 2D clip")
    func alternates() {
        let clips = superCycle(key)
        #expect(clips.count == 2 * LoadingSequence.superCycleBags.flat * flatClips.count)
        let flatNames = Set(flatClips.map(\.name))
        let solidNames = Set(solidClips.map(\.name))
        for (index, clip) in clips.enumerated() {
            #expect((index.isMultiple(of: 2) ? flatNames : solidNames).contains(clip.name), "slot \(index) is \(clip.name)")
        }
    }

    @Test("the 2D slots keep the desktop order, minus eyes-only clips")
    func flatOrderUnchanged() {
        let bags = LoadingSequence.superCycleBags.flat
        for key in ["alpha", key, "", "Nova"] {
            let sequence = LoadingSequence(key: key)
            for index in 0..<3 {
                let played = sequence.clips(inSuperCycle: index).enumerated().filter { $0.offset.isMultiple(of: 2) }.map(\.element.name)
                let expected = (index * bags..<(index + 1) * bags).flatMap { sequence.playedBag($0) }.map { LoadingClips.all[$0].name }
                #expect(played == Array(expected), "\(key) super cycle \(index)")
            }
        }
    }

    @Test("clips that move only the eyes never play")
    func noEyesOnlyClips() {
        let sequence = LoadingSequence(key: key)
        let names = (0..<2).flatMap { sequence.clips(inSuperCycle: $0) }.map(\.name)
        for name in ["squint", "dot-stare", "eye-morph"] { #expect(!names.contains(name), "\(name) still plays") }
        #expect(Set(names) == Set(flatClips.map(\.name) + solidClips.map(\.name)))
    }

    @Test("every 3D bag plays each clip once and nothing repeats back to back")
    func solidBags() {
        for key in (0..<30).map({ "bot-\($0)" }) {
            let sequence = LoadingSequence(key: key)
            for index in 0..<40 { #expect(sequence.solidBag(index).sorted() == Array(0..<solidClips.count)) }
            let order = (0..<40).flatMap { sequence.solidBag($0) }
            #expect(zip(order, order.dropFirst()).allSatisfy { $0 != $1 }, "repeat for \(key)")
        }
    }

    @Test("the 3D order is deterministic per bot and differs between bots")
    func perBot() {
        let keys = (0..<24).map { "bot-\($0)" }
        let orders = keys.map { LoadingSequence(key: $0).solidBag(0) }
        #expect(orders == keys.map { LoadingSequence(key: $0).solidBag(0) })
        #expect(Set(orders).count >= 20)
        #expect(LoadingSequence(key: "a").solidBag(0) != LoadingSequence(key: "a").bag(0).prefix(15).map { $0 })
    }

    @Test("a super cycle lasts exactly the sum of its clips and the timeline walks it")
    func walks() {
        let sequence = LoadingSequence(key: key)
        let clips = sequence.clips(inSuperCycle: 0)
        #expect(abs(clips.reduce(0) { $0 + $1.duration } - LoadingSequence.superCycleDuration) < 1e-6)
        var start = 0.0
        for clip in clips {
            let middle = clip.pose(at: clip.duration / 2)
            #expect(close(sequence.pose(at: start + clip.duration / 2), middle), "\(clip.name)")
            start += clip.duration
        }
        let next = sequence.clips(inSuperCycle: 1)[0]
        #expect(close(sequence.pose(at: LoadingSequence.superCycleDuration + next.duration / 2), next.pose(at: next.duration / 2)))
    }

    @Test("every clip boundary lands on facing, including across super cycles")
    func seamless() {
        let sequence = LoadingSequence(key: key)
        var boundary = 0.0
        for index in 0..<2 {
            for clip in sequence.clips(inSuperCycle: index) {
                #expect(onFacing(sequence.pose(at: boundary)), "\(clip.name) not facing at \(boundary)")
                boundary += clip.duration
            }
        }
        #expect(onFacing(sequence.pose(at: 0)) && onFacing(sequence.pose(at: -2)))
    }

    @Test("without 3D clips the sequence is the plain 2D bag walk")
    func flatOnly() {
        let flat = LoadingSequence(key: key, interleavesSolid: false)
        let order = flat.playedBag(0)
        var start = 0.0
        for index in order {
            let clip = LoadingClips.all[index]
            #expect(close(flat.pose(at: start + clip.duration / 2), clip.pose(at: clip.duration / 2)))
            start += clip.duration
        }
    }

    @Test("sigil and photo avatars never play 3D clips, solids do")
    func contentRouting() {
        let seed = LoadingSequence.seed(for: key)
        let flatCycle = LoadingClips.cycleDuration
        func poses(_ solid: Bool) -> [AvatarPose] {
            samples(0...(flatCycle * 1.5), step: 0.05).map { AvatarMotion.pose(.work, at: $0, seed: seed, solidClips: solid) }
        }
        #expect(poses(false).allSatisfy { $0.yaw == 0 && $0.pitch == 0 && $0.pairSpin == 0 })
        #expect(poses(true).contains { $0.yaw != 0 || $0.pitch != 0 })
        #expect(AvatarContent(BotAvatarSpec(name: "Rune", meta: BotAvatarMeta(shape: "sigil-3", color: "#f5a524", custom: true))).isSolid == false)
        #expect(AvatarContent(BotAvatarSpec(name: "Atlas", meta: BotAvatarMeta(shape: "squircle", color: "#3e8ef7", custom: true))).isSolid)
    }

    @Test("the working dots still ride on top of the 3D clips")
    func dotsSurvive() {
        let seed = LoadingSequence.seed(for: key)
        let moving = samples(0...30, step: 0.1).map { AvatarMotion.pose(.work, at: $0, seed: seed) }
        #expect(moving.allSatisfy { $0.dots.x >= 0.2 && $0.dots.y >= 0.2 })
    }
}
