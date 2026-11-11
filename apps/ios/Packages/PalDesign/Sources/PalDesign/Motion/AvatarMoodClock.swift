import Foundation
import SwiftUI

struct AvatarMoodClock: Equatable, Sendable {
    var mood: AvatarMood
    var since: Date
    var from: AvatarPose?
    var blinkDelay: Double
    var loadingSeed: UInt64
    var reduceMotion: Bool

    init(
        mood: AvatarMood, since: Date, blinkDelay: Double, loadingSeed: UInt64, reduceMotion: Bool, from: AvatarPose? = nil
    ) {
        self.mood = mood
        self.since = since
        self.blinkDelay = blinkDelay
        self.loadingSeed = loadingSeed
        self.reduceMotion = reduceMotion
        self.from = from
    }

    func changing(to mood: AvatarMood, at date: Date) -> AvatarMoodClock {
        AvatarMoodClock(
            mood: mood, since: date, blinkDelay: blinkDelay, loadingSeed: loadingSeed, reduceMotion: reduceMotion, from: pose(at: date)
        )
    }

    func pose(at date: Date) -> AvatarPose {
        let t = date.timeIntervalSince(since)
        var pose = AvatarMotion.pose(mood, at: t, reduceMotion: reduceMotion, seed: sessionSeed)
        if let from, !reduceMotion, t < AvatarMotion.settleDuration {
            pose = from.blended(to: pose, Ease.easeOut(max(0, t) / AvatarMotion.settleDuration))
        }
        if blinks(at: t) {
            pose.eyeOpen *= AvatarBlink.openness(at: date.timeIntervalSinceReferenceDate, delay: blinkDelay)
        }
        return pose
    }

    func nextUpdate(after date: Date, frameInterval: TimeInterval) -> Date? {
        let candidate = date.addingTimeInterval(frameInterval)
        if isMoving(at: date) || isMoving(at: candidate) { return candidate }
        let oneShotEnd = since.addingTimeInterval(oneShotDuration)
        if candidate < oneShotEnd { return oneShotEnd }
        guard blinks(at: candidate.timeIntervalSince(since)) else { return nil }
        let blinkStart = AvatarBlink.nextStart(after: candidate.timeIntervalSinceReferenceDate, delay: blinkDelay)
        return Date(timeIntervalSinceReferenceDate: blinkStart)
    }

    var sessionSeed: UInt64 {
        loadingSeed ^ UInt64(truncatingIfNeeded: Int64((since.timeIntervalSince1970 * 1000).rounded(.down)))
    }

    private var oneShotDuration: Double {
        AvatarMotion.oneShotDuration(mood, reduceMotion: reduceMotion)
    }

    private func isMoving(at date: Date) -> Bool {
        let t = date.timeIntervalSince(since)
        if from != nil, !reduceMotion, t < AvatarMotion.settleDuration { return true }
        if AvatarMotion.isLooping(mood) { return true }
        if !reduceMotion, t < oneShotDuration { return true }
        return blinks(at: t) && AvatarBlink.openness(at: date.timeIntervalSinceReferenceDate, delay: blinkDelay) < 1
    }

    private func blinks(at t: Double) -> Bool {
        guard !reduceMotion else { return false }
        return mood == .idle || (mood == .done && t >= oneShotDuration)
    }
}

struct AvatarSchedule: TimelineSchedule, Sendable {
    let clock: AvatarMoodClock
    let frameInterval: TimeInterval

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> UnfoldFirstSequence<Date> {
        let clock = clock
        let interval = mode == .lowFrequency ? max(frameInterval, 1) : frameInterval
        return sequence(first: startDate) { clock.nextUpdate(after: $0, frameInterval: interval) }
    }
}
