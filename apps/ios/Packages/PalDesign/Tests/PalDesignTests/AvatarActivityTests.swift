import Foundation
import SwiftUI
import Testing
@testable import PalDesign

private final class BuildCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func bump() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

private let origin = Date(timeIntervalSinceReferenceDate: 1_000)

private func framesDrawn(_ activity: AvatarActivity, over seconds: TimeInterval) -> Int {
    let clock = AvatarMoodClock(
        mood: activity.mood, since: origin, blinkDelay: 1.3, loadingSeed: 7,
        reduceMotion: activity.reduceMotion, restingBlinks: activity.blinksAtRest
    )
    guard activity.ticks(settling: clock.isSettling(at: origin)) else { return 0 }
    let end = origin.addingTimeInterval(seconds)
    let schedule = AvatarSchedule(clock: clock, frameInterval: activity.frameInterval)
    return schedule.entries(from: origin, mode: .normal).prefix(while: { $0 < end }).count
}

@Suite("Avatar activity")
struct AvatarActivityTests {
    @Test("twenty resting small avatars draw no frame over a minute")
    func restingSmallAvatarsDrawNothing() {
        let sizes: [CGFloat] = [25.3, 28, 30, 34, 40.8, 43, 47]
        let drawn = (0..<20).reduce(0) { total, index in
            let activity = AvatarActivity(mood: .idle, size: sizes[index % sizes.count], animated: true, reduceMotion: false)
            return total + framesDrawn(activity, over: 60)
        }
        #expect(drawn == 0)
    }

    @Test("an active avatar animates at the capped rate at any size", arguments: [AvatarMood.work, .think])
    func activeAvatarAnimates(mood: AvatarMood) {
        for size in [CGFloat(25.3), 66] {
            let frames = framesDrawn(AvatarActivity(mood: mood, size: size, animated: true, reduceMotion: false), over: 10)
            #expect(frames >= 295 && frames <= 305)
        }
    }

    @Test("a large resting avatar draws only its blinks, at no more than 30 frames per second")
    func largeRestingAvatarBlinks() {
        let activity = AvatarActivity(mood: .idle, size: 66, animated: true, reduceMotion: false)
        let frames = framesDrawn(activity, over: 60)
        #expect(frames > 0)
        #expect(frames < 15 * 8)
        #expect(activity.frameInterval >= 1.0 / 30)
        #expect(AvatarActivity(mood: .work, size: 22, animated: true, reduceMotion: true).frameInterval >= 1.0 / 20)
    }

    @Test("a still avatar never ticks and installs no pointer tracking")
    func stillAvatarIsInert() {
        let still = AvatarActivity(mood: .work, size: 66, animated: false, reduceMotion: false)
        #expect(!still.ticks(settling: true))
        #expect(!still.tracksPointer)
        #expect(AvatarActivity(mood: .idle, size: 30, animated: true, reduceMotion: false).tracksPointer)
    }

    @Test("a small avatar settles after work ends, then stops asking for frames")
    func smallAvatarSettlesThenStops() {
        let working = AvatarMoodClock(
            mood: .work, since: origin, blinkDelay: 1, loadingSeed: 3, reduceMotion: false, restingBlinks: false
        )
        let ended = working.changing(to: .idle, at: origin.addingTimeInterval(5))
        let activity = AvatarActivity(mood: .idle, size: 30, animated: true, reduceMotion: false)
        let during = origin.addingTimeInterval(5.1)
        let after = origin.addingTimeInterval(5.5)
        #expect(ended.isSettling(at: during))
        #expect(activity.ticks(settling: ended.isSettling(at: during)))
        #expect(!activity.ticks(settling: ended.isSettling(at: after)))
        #expect(ended.nextUpdate(after: after, frameInterval: AvatarActivity.loopInterval) == nil)
    }

    @Test("blinks are scheduled only when the avatar is large enough")
    func blinksFollowSize() {
        let large = AvatarMoodClock(mood: .idle, since: origin, blinkDelay: 1, loadingSeed: 3, reduceMotion: false, restingBlinks: true)
        var small = large
        small.restingBlinks = false
        #expect(large.nextUpdate(after: origin, frameInterval: AvatarActivity.loopInterval) != nil)
        #expect(small.nextUpdate(after: origin, frameInterval: AvatarActivity.loopInterval) == nil)
    }
}

@Suite("Avatar shared clock and slot")
struct AvatarSharedClockTests {
    private func workingFrames(_ count: Int, over seconds: TimeInterval) -> Set<Date> {
        let activity = AvatarActivity(mood: .work, size: 30, animated: true, reduceMotion: false)
        let end = origin.addingTimeInterval(seconds)
        var instants = Set<Date>()
        for index in 0..<count {
            let start = origin.addingTimeInterval(Double(index) * 0.0071 + 0.0013)
            let clock = AvatarMoodClock(
                mood: .work, since: start, blinkDelay: Double(index) * 0.37, loadingSeed: UInt64(index),
                reduceMotion: false, restingBlinks: false
            )
            let schedule = AvatarSchedule(clock: clock, frameInterval: activity.frameInterval)
            instants.formUnion(schedule.entries(from: start, mode: .normal).dropFirst().prefix(while: { $0 < end }))
        }
        return instants
    }

    @Test("ten working avatars started at different moments cost the entries of one")
    func workingAvatarsShareOneGrid() {
        let one = workingFrames(1, over: 10)
        let ten = workingFrames(10, over: 10)
        #expect(one.count >= 295 && one.count <= 305)
        #expect(ten == one)
    }

    @Test("every entry sits on the 1/30 s grid")
    func entriesSitOnTheGrid() {
        for instant in workingFrames(3, over: 5) {
            let cells = instant.timeIntervalSinceReferenceDate / AvatarActivity.loopInterval
            #expect(abs(cells - cells.rounded()) < 1e-3)
        }
    }

    @Test("a paused avatar asks for no frame, so it records no avatar.frame and no avatar.canvas.draw")
    func pausedAvatarDrawsNothing() {
        for mood in AvatarMood.allCases {
            for size in [CGFloat(30), 66] {
                let paused = AvatarActivity(mood: mood, size: size, animated: true, reduceMotion: false, paused: true)
                #expect(!paused.ticks(settling: true))
                #expect(framesDrawn(paused, over: 60) == 0)
            }
        }
    }

    @MainActor
    @Test("eight working rows share one slot: one ticks, releasing hands the slot on")
    func rowsShareOneSlot() {
        let budget = AvatarSlotBudget(capacity: 1)
        let rows = (0..<8).map { _ in UUID() }
        rows.forEach { budget.request($0) }
        func ticking() -> [UUID] {
            rows.filter { id in
                AvatarActivity(mood: .work, size: 30, animated: true, reduceMotion: false, paused: !budget.holds(id))
                    .ticks(settling: false)
            }
        }
        #expect(ticking() == [rows[0]])
        budget.request(rows[0])
        #expect(ticking() == [rows[0]])
        budget.release(rows[3])
        #expect(ticking() == [rows[0]])
        budget.release(rows[0])
        #expect(ticking() == [rows[1]])
        budget.release(rows[1])
        budget.release(rows[2])
        #expect(ticking() == [rows[4]])
    }
}

@Suite("Avatar content store")
struct AvatarContentStoreTests {
    private let spec = BotAvatarSpec(name: "Atlas", meta: BotAvatarMeta(shape: SolidTestShapes.blobs[0], color: "#3e8ef7", custom: true))

    private func store(counting counter: BuildCounter) -> AvatarContentStore {
        AvatarContentStore { spec, scheme, ink in
            counter.bump()
            return AvatarContentStore.make(spec, scheme, ink)
        }
    }

    @Test("fifty view caches decode one bot and scheme once")
    func viewCachesShareOneDecode() {
        let counter = BuildCounter()
        let shared = store(counting: counter)
        for _ in 0..<50 {
            let cache = AvatarContentCache(store: shared)
            _ = cache.resolve(spec, .light, eyeInk: nil)
            _ = cache.resolve(spec, .light, eyeInk: nil)
        }
        #expect(counter.value == 1)
        _ = AvatarContentCache(store: shared).resolve(spec, .dark, eyeInk: nil)
        #expect(counter.value == 2)
    }

    @Test("the store forgets its oldest entry past capacity")
    func evictsOldestEntry() {
        let counter = BuildCounter()
        let shared = store(counting: counter)
        func tinted(_ index: Int) -> BotAvatarSpec {
            let color = "#" + String(format: "%06x", 0x101010 + index * 0x010203)
            return BotAvatarSpec(name: "Atlas", meta: BotAvatarMeta(shape: SolidTestShapes.blobs[0], color: color, custom: true))
        }
        for index in 0...AvatarContentStore.capacity {
            _ = shared.content(for: tinted(index), scheme: .light, eyeInk: nil)
        }
        #expect(counter.value == AvatarContentStore.capacity + 1)
        _ = shared.content(for: tinted(0), scheme: .light, eyeInk: nil)
        #expect(counter.value == AvatarContentStore.capacity + 2)
    }
}
