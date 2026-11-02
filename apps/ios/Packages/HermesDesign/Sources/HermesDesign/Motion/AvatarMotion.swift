import Foundation

enum Ease: Sendable {
    case linear
    case easeIn
    case easeOut
    case easeInOut

    func callAsFunction(_ x: Double) -> Double {
        switch self {
        case .linear: x
        case .easeIn: x * x
        case .easeOut: 1 - (1 - x) * (1 - x)
        case .easeInOut: x < 0.5 ? 2 * x * x : 1 - pow(-2 * x + 2, 2) / 2
        }
    }
}

struct Keyframe: Sendable {
    var time: Double
    var pose: AvatarPose
    var ease: Ease
}

struct KeyframeTrack: Sendable {
    let keys: [Keyframe]

    var duration: Double { keys.last?.time ?? 0 }

    init(_ keys: [Keyframe]) {
        precondition(zip(keys, keys.dropFirst()).allSatisfy { $0.time <= $1.time }, "keyframes out of order")
        self.keys = keys
    }

    func pose(at t: Double) -> AvatarPose {
        guard let first = keys.first, let last = keys.last else { return .rest }
        if t <= first.time { return first.pose }
        if t >= last.time { return last.pose }
        let next = keys.firstIndex { $0.time > t } ?? keys.count - 1
        let from = keys[next - 1]
        let to = keys[next]
        let progress = (t - from.time) / (to.time - from.time)
        return from.pose.blended(to: to.pose, to.ease(progress))
    }
}

enum AvatarMotion {
    static let settleDuration = 0.4
    static let reducedPulsePeriod = 2.0
    static let reducedDoneDuration = 1.2

    static var loopDuration: Double { loading.duration }
    static var doneDuration: Double { done.duration }

    static func pose(_ mood: AvatarMood, at t: Double, reduceMotion: Bool = false) -> AvatarPose {
        switch (mood, reduceMotion) {
        case (.idle, _):
            return .rest
        case (.think, false), (.work, false):
            var pose = loading.pose(at: loopTime(t))
            pose.dots = workingDots(mood, at: t)
            return pose
        case (.think, true), (.work, true):
            return AvatarPose.rest.with {
                $0.opacity = 0.8 + 0.2 * cos(2 * Double.pi * t / reducedPulsePeriod)
                $0.dots = workingDots(mood, at: 0)
            }
        case (.done, false):
            return done.pose(at: t)
        case (.done, true):
            return t < reducedDoneDuration ? AvatarPose.rest.with { $0.eyeHappy = 1 } : .rest
        }
    }

    static func staticPose(_ mood: AvatarMood) -> AvatarPose {
        AvatarPose.rest.with { $0.dots = workingDots(mood, at: 0) }
    }

    static func isLooping(_ mood: AvatarMood) -> Bool {
        mood == .think || mood == .work
    }

    static func oneShotDuration(_ mood: AvatarMood, reduceMotion: Bool) -> Double {
        guard mood == .done else { return 0 }
        return reduceMotion ? reducedDoneDuration : doneDuration
    }

    private static func loopTime(_ t: Double) -> Double {
        let period = loopDuration
        let wrapped = t.truncatingRemainder(dividingBy: period)
        return wrapped < 0 ? wrapped + period : wrapped
    }

    private static func workingDots(_ mood: AvatarMood, at t: Double) -> SIMD3<Double> {
        let rate: Double
        switch mood {
        case .think: rate = 2.4
        case .work: rate = 2.6
        case .idle, .done: return SIMD3(0, 0, 0)
        }
        func dot(_ index: Double) -> Double { 0.2 + 0.8 * max(0, sin(t * rate - index * 0.7)) }
        return SIMD3(dot(0), dot(1), dot(2))
    }

    private static func key(_ time: Double, _ ease: Ease, _ pose: AvatarPose) -> Keyframe {
        Keyframe(time: time, pose: pose, ease: ease)
    }

    private static func key(_ time: Double, _ pose: AvatarPose) -> Keyframe {
        Keyframe(time: time, pose: pose, ease: .easeInOut)
    }

    private static let facing = AvatarPose.facing
    private static let lookDownLeft = facing.with {
        $0.eyeX = -0.13; $0.eyeY = 0.11; $0.eyeRoll = 33; $0.bodyX = -0.03; $0.bodyRotation = 4
    }
    private static let lookDown = facing.with { $0.eyeY = 0.19; $0.bodyX = -0.005 }
    private static let lookDownRight = facing.with {
        $0.eyeX = 0.17; $0.eyeY = 0.12; $0.eyeRoll = -36; $0.bodyX = 0.02; $0.bodyRotation = -4
    }
    private static let lookUpLeft = facing.with {
        $0.eyeX = -0.13; $0.eyeY = -0.12; $0.eyeRoll = 15; $0.bodyX = -0.06; $0.bodyRotation = 3
    }
    private static let lookUpRight = facing.with {
        $0.eyeX = 0.11; $0.eyeY = -0.13; $0.eyeRoll = -13; $0.bodyX = 0.03; $0.bodyRotation = -3
    }
    private static let lookUp = facing.with { $0.eyeY = -0.18; $0.bodyY = -0.035 }
    private static let dropped = facing.with { $0.bodyY = 0.1 }
    private static let squint = facing.with { $0.eyeScale = 0.55; $0.eyeDot = 0.6 }
    static let offstage = 0.9

    static let loading = KeyframeTrack([
        key(0.00, facing),
        key(0.42, facing),
        key(0.52, .easeIn, facing.with { $0.eyeX = 0.12 }),
        key(0.62, .easeIn, facing.with { $0.eyeX = offstage; $0.bodyScaleY = 0.72; $0.opacity = 0.9 }),
        key(0.62, facing.with { $0.eyeX = -offstage; $0.bodyScaleY = 0.72; $0.opacity = 0.9 }),
        key(0.72, .easeOut, facing.with {
            $0.eyeX = -offstage; $0.bodyScaleX = 0.56; $0.bodyScaleY = 0.56; $0.opacity = 0.85
        }),
        key(0.82, .easeIn, facing.with { $0.eyeX = -0.75; $0.bodyScaleX = 0.94; $0.bodyScaleY = 0.74; $0.opacity = 0.92 }),
        key(0.95, .easeOut, facing.with { $0.eyeX = -0.42 }),
        key(1.20, .easeOut, lookDownLeft),
        key(1.75, .easeIn, lookDown),
        key(2.35, .easeOut, lookDownRight),
        key(2.80, lookDownLeft),
        key(3.35, .easeIn, lookDown),
        key(3.95, .easeOut, lookDownRight),
        key(4.40, lookDownLeft),
        key(4.70, .easeOut, facing),
        key(5.45, facing),
        key(5.85, lookUpLeft),
        key(5.95, lookUpLeft),
        key(6.03, .easeIn, lookUpLeft.with { $0.eyeOpen = 0.1 }),
        key(6.12, .easeOut, lookUpLeft),
        key(6.45, lookUpLeft.with { $0.eyeY = -0.16 }),
        key(6.95, lookUpRight),
        key(7.45, lookUpRight),
        key(7.85, lookUp),
        key(7.95, lookUp),
        key(8.05, .easeIn, dropped.with { $0.eyeY = -0.1; $0.bodyScaleX = 1.04; $0.bodyScaleY = 0.94 }),
        key(8.20, .easeOut, dropped.with { $0.eyeY = 0.11 }),
        key(8.35, dropped.with { $0.eyeY = 0.08 }),
        key(8.48, dropped.with { $0.eyeY = -0.02 }),
        key(8.58, .easeIn, dropped.with { $0.eyeY = -0.3 }),
        key(8.66, .easeIn, dropped.with { $0.eyeY = -offstage }),
        key(8.66, dropped.with { $0.eyeY = offstage }),
        key(8.76, .easeOut, facing.with { $0.eyeY = 0.36 }),
        key(8.88, .easeOut, facing.with { $0.eyeY = 0.18 }),
        key(9.10, .easeOut, facing),
        key(9.20, facing),
        key(9.38, squint),
        key(9.62, squint),
        key(9.90, facing),
    ])

    private static let happy = facing.with { $0.eyeHappy = 1; $0.eyeY = -0.02 }

    static let done = KeyframeTrack([
        key(0.00, facing),
        key(0.16, facing.with { $0.eyeScale = 0.65; $0.eyeDot = 0.3; $0.bodyY = 0.03 }),
        key(0.30, .easeOut, happy),
        key(0.48, happy.with { $0.bodyScaleX = 1.07; $0.bodyScaleY = 0.95; $0.bodyY = 0.02 }),
        key(0.64, .easeOut, happy.with {
            $0.bodyY = -0.15; $0.bodyScaleX = 0.96; $0.bodyScaleY = 1.08; $0.bodyRotation = -8; $0.eyeX = -0.05; $0.eyeY = -0.08
        }),
        key(0.80, .easeOut, happy.with { $0.bodyY = -0.16; $0.bodyRotation = -10; $0.eyeX = -0.05; $0.eyeY = -0.08 }),
        key(0.98, .easeIn, happy.with { $0.bodyScaleX = 1.08; $0.bodyScaleY = 0.94; $0.bodyRotation = -4 }),
        key(1.12, .easeOut, happy.with {
            $0.bodyY = -0.13; $0.bodyScaleX = 0.97; $0.bodyScaleY = 1.06; $0.bodyRotation = 9; $0.eyeX = 0.05; $0.eyeY = -0.07
        }),
        key(1.26, .easeOut, happy.with { $0.bodyY = -0.14; $0.bodyRotation = 10; $0.eyeX = 0.05; $0.eyeY = -0.07 }),
        key(1.44, .easeIn, happy.with { $0.bodyScaleX = 1.05; $0.bodyScaleY = 0.96; $0.bodyRotation = 3 }),
        key(1.56, .easeOut, happy.with { $0.bodyY = -0.05 }),
        key(1.70, happy),
        key(1.80, happy),
        key(1.92, .easeOut, facing.with { $0.eyeScale = 0.7 }),
        key(2.10, facing.with { $0.eyeScale = 0.7 }),
        key(2.40, .rest),
    ])
}
