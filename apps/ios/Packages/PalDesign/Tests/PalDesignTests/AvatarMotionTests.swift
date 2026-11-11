import Foundation
import SwiftUI
import Testing
@testable import PalDesign

let testSeed = LoadingSequence.seed(for: "alpha")
private let done = AvatarMood.doneDuration
let frame = 1.0 / 120
let allFields = AvatarPose.geometry + AvatarPose.appearance

private func pose(_ mood: AvatarMood, _ t: Double, reduceMotion: Bool = false) -> AvatarPose {
    AvatarMotion.pose(mood, at: t, reduceMotion: reduceMotion, seed: testSeed)
}

func samples(_ range: ClosedRange<Double>, step: Double = frame) -> [Double] {
    Array(stride(from: range.lowerBound, through: range.upperBound, by: step))
}

func eyesHidden(_ pose: AvatarPose) -> Bool {
    abs(pose.eyeX) >= 0.75 || abs(pose.eyeY) >= 0.75
}

func visibleJump(_ a: AvatarPose, _ b: AvatarPose) -> Bool {
    if eyesHidden(a) || eyesHidden(b) {
        return abs(a.bodyScaleX - b.bodyScaleX) > 0.1 || abs(a.bodyY - b.bodyY) > 0.05
    }
    let limits: [(any WritableKeyPath<AvatarPose, Double> & Sendable, Double)] = [
        (\.eyeX, 0.2), (\.eyeY, 0.2), (\.eyeRoll, 6), (\.front, 0.1), (\.eyeScale, 0.1),
        (\.bodyX, 0.05), (\.bodyY, 0.05), (\.bodyScaleX, 0.1), (\.bodyScaleY, 0.1),
        (\.bodyRotation, 3), (\.opacity, 0.1), (\.eyeOpen, 0.5),
    ]
    return limits.contains { key, limit in abs(a[keyPath: key] - b[keyPath: key]) > limit }
}

private func date(_ seconds: Double) -> Date {
    Date(timeIntervalSinceReferenceDate: 800_000_000 + seconds)
}

private func ignoringBlink(_ pose: AvatarPose) -> AvatarPose {
    pose.with { $0.eyeOpen = 1 }
}

private func noBlinkDelay(around seconds: ClosedRange<Double>) -> Double {
    let candidates = stride(from: 0.0, to: AvatarBlink.spreadSeconds, by: 0.05)
    return candidates.first { delay in
        samples(seconds, step: 0.01).allSatisfy {
            AvatarBlink.openness(at: date($0).timeIntervalSinceReferenceDate, delay: delay) == 1
        }
    } ?? 0
}

@Suite("Done plays once and lands on idle")
struct DoneTests {
    @Test("it lasts between 1.5 and 2.5 seconds")
    func duration() {
        #expect((1.5...2.5).contains(done))
    }

    @Test("it starts from the loading pose")
    func startsFromLoading() {
        var working = pose(.work, 0)
        working.dots = .zero
        #expect(pose(.done, 0) == working)
    }

    @Test("it reaches happy ^^ eyes with a hop")
    func reachesHappy() {
        let window = samples(0...done).map { pose(.done, $0) }
        #expect(window.contains { $0.eyeHappy == 1 && $0.bodyY < -0.1 })
        #expect(window.filter { $0.eyeHappy == 1 }.count > Int(0.8 / frame))
    }

    @Test("it ends exactly on the idle pose and stays there")
    func endsIdle() {
        for t in [done, done + 0.5, done + 60] {
            #expect(pose(.done, t) == pose(.idle, 0))
        }
        #expect(pose(.idle, 0) == AvatarMotion.staticPose(.idle))
    }

    @Test("re-entering done replays it")
    func replays() {
        var clock = AvatarMoodClock(mood: .work, since: date(0), blinkDelay: 0, loadingSeed: testSeed, reduceMotion: false)
        clock = clock.changing(to: .done, at: date(2))
        #expect(clock.pose(at: date(2.9)).eyeHappy == 1)
        #expect(ignoringBlink(clock.pose(at: date(2 + done + 1))) == .rest)
        clock = clock.changing(to: .idle, at: date(10))
        clock = clock.changing(to: .work, at: date(12))
        clock = clock.changing(to: .done, at: date(20))
        #expect(clock.pose(at: date(20.9)).eyeHappy == 1)
        #expect(ignoringBlink(clock.pose(at: date(20 + done + 1))) == .rest)
    }
}

@Suite("Mood changes settle smoothly")
struct SettleTests {
    @Test("a mood change starts from the pose on screen and settles in 0.4 s")
    func settles() {
        let delay = noBlinkDelay(around: 1.2...2)
        let working = AvatarMoodClock(mood: .work, since: date(0), blinkDelay: delay, loadingSeed: testSeed, reduceMotion: false)
        let shown = working.pose(at: date(1.3))
        let idle = working.changing(to: .idle, at: date(1.3))
        #expect(idle.pose(at: date(1.3)) == shown)
        #expect(!visibleJump(shown, idle.pose(at: date(1.3 + frame))))
        #expect(idle.pose(at: date(1.3 + AvatarMotion.settleDuration)) == .rest)
    }
}

@Suite("Reduce Motion")
struct ReduceMotionTests {
    @Test("no mood moves any geometry", arguments: AvatarMood.allCases)
    func staysStill(mood: AvatarMood) {
        for t in samples(0...12, step: 0.05) {
            let shown = pose(mood, t, reduceMotion: true)
            for key in AvatarPose.geometry {
                #expect(shown[keyPath: key] == AvatarPose.rest[keyPath: key], "\(mood) moves \(key) at t=\(t)")
            }
        }
    }

    @Test("loading pulses opacity instead")
    func pulses() {
        let opacities = samples(0...4, step: 0.05).map { pose(.work, $0, reduceMotion: true).opacity }
        #expect(opacities.max()! == 1 && opacities.min()! < 0.7)
    }

    @Test("done shows a static ^^ frame, then idle")
    func doneFrame() {
        #expect(pose(.done, 0.2, reduceMotion: true).eyeHappy == 1)
        #expect(pose(.done, 2, reduceMotion: true) == .rest)
    }

    @Test("mood changes swap instantly and never blink")
    func noSettleOrBlink() {
        let working = AvatarMoodClock(mood: .work, since: date(0), blinkDelay: 0, loadingSeed: testSeed, reduceMotion: true)
        let idle = working.changing(to: .idle, at: date(1.3))
        for t in samples(1.3...10, step: 0.01) {
            #expect(idle.pose(at: date(t)) == .rest)
        }
    }
}

@Suite("Blink")
struct BlinkTests {
    @Test("the delay matches the desktop's per-name hash")
    func desktopDelay() {
        #expect(abs(AvatarBlink.delaySeconds(for: "a") - 0.388) < 1e-9)
        #expect(abs(AvatarBlink.delaySeconds(for: "ab") - Double((97 * 31 + 98) % 1000) / 1000 * 4) < 1e-9)
    }

    @Test("the schedule is deterministic per name and spread across names")
    func deterministic() {
        let names = (0..<24).map { "bot-\($0)" }
        let first = names.map(AvatarBlink.delaySeconds(for:))
        #expect(first == names.map(AvatarBlink.delaySeconds(for:)))
        #expect(first.allSatisfy { (0..<AvatarBlink.spreadSeconds).contains($0) })
        #expect(Set(first).count >= 12)
    }

    @Test("a blink closes the eyes for about 0.17 s every 4.2 s")
    func shape() {
        let delay = AvatarBlink.delaySeconds(for: "agent")
        let closed = samples(0...(3 * AvatarBlink.period), step: 0.001).filter {
            AvatarBlink.openness(at: $0, delay: delay) < 1
        }
        #expect(closed.count >= 3 * 160 && closed.count <= 3 * 170)
        let deepest = closed.map { AvatarBlink.openness(at: $0, delay: delay) }.min()!
        #expect(abs(deepest - AvatarBlink.closedScale) < 0.01)
    }

    @Test("same spec, same blink; idle blinks and loading does not")
    func viewKey() {
        let a = BotAvatarSpec(name: "Nova", meta: BotAvatarMeta())
        let b = BotAvatarSpec(name: "Nova", meta: BotAvatarMeta())
        #expect(a.blinkKey == b.blinkKey)
        #expect(a.blinkKey != BotAvatarSpec(name: "Orion", meta: BotAvatarMeta()).blinkKey)

        let delay = AvatarBlink.delaySeconds(for: a.blinkKey)
        let idle = AvatarMoodClock(mood: .idle, since: date(0), blinkDelay: delay, loadingSeed: testSeed, reduceMotion: false)
        let opened = samples(0...10, step: 0.005).map { idle.pose(at: date($0)).eyeOpen }
        #expect(opened.min()! < 0.2)
    }
}

@Suite("Timeline cost")
struct ScheduleTests {
    private func entries(_ clock: AvatarMoodClock, over seconds: Double) -> [Date] {
        let schedule = AvatarSchedule(clock: clock, frameInterval: 1.0 / 60)
        return Array(schedule.entries(from: clock.since, mode: .normal).prefix { $0 <= clock.since.addingTimeInterval(seconds) })
    }

    @Test("idle avatars only wake up around blinks")
    func idleIsCheap() {
        let delay = AvatarBlink.delaySeconds(for: "agent")
        let clock = AvatarMoodClock(mood: .idle, since: date(0), blinkDelay: delay, loadingSeed: testSeed, reduceMotion: false)
        let ticks = entries(clock, over: 21)
        #expect(ticks.count <= 1 + 5 * 13)
        for tick in ticks.dropFirst() {
            let previous = tick.addingTimeInterval(-1.0 / 60).timeIntervalSinceReferenceDate
            let now = tick.timeIntervalSinceReferenceDate
            let blinking = AvatarBlink.openness(at: now, delay: delay) < 1
                || AvatarBlink.openness(at: previous, delay: delay) < 1
                || AvatarBlink.openness(at: now + 1.0 / 60, delay: delay) < 1
            #expect(blinking, "idle tick outside a blink at \(now)")
        }
    }

    @Test("loading animates every frame")
    func loadingTicks() {
        let clock = AvatarMoodClock(mood: .work, since: date(0), blinkDelay: 0, loadingSeed: testSeed, reduceMotion: false)
        #expect(entries(clock, over: 1).count >= 60)
    }

    @Test("done animates until it lands, then only blinks")
    func doneTicks() {
        let delay = noBlinkDelay(around: (done + 0.1)...(done + 3))
        let clock = AvatarMoodClock(mood: .done, since: date(0), blinkDelay: delay, loadingSeed: testSeed, reduceMotion: false)
        let ticks = entries(clock, over: done + 3)
        #expect(ticks.filter { $0 <= date(done) }.count >= Int(done * 60) - 1)
        #expect(ticks.filter { $0 > date(done + 0.1) }.isEmpty)
        #expect(clock.pose(at: ticks.last!) == .rest)
    }

    @Test("reduced done wakes once to return to idle")
    func reducedDone() {
        let clock = AvatarMoodClock(mood: .done, since: date(0), blinkDelay: 0, loadingSeed: testSeed, reduceMotion: true)
        let ticks = entries(clock, over: 10)
        #expect(ticks.count == 2)
        #expect(clock.pose(at: ticks[1]) == .rest)
    }
}
