import Foundation

enum SolidClips {
    static let envelope = 0.3
    static let travel = 0.65

    static let all: [LoadingClip] = [
        spinAround, lookOrbit, readingLines, hop, ponderUp, dotChase, jelly, rollOver,
        frontFlip, peekaboo, dizzyEyes, nodding, glanceAround, sleepyDroop,
    ]

    static let cycleDuration: Double = all.reduce(0) { $0 + $1.duration }

    private typealias Field = any WritableKeyPath<AvatarPose, Double> & Sendable

    private static let tau = 2 * Double.pi

    private static func cycle(_ t: Double, _ period: Double) -> Double {
        (t.truncatingRemainder(dividingBy: period) + period).truncatingRemainder(dividingBy: period) / period
    }

    private static func smooth(_ x: Double) -> Double {
        let c = min(1, max(0, x))
        return c * c * (3 - 2 * c)
    }

    private static func span(_ p: Double, _ a: Double, _ b: Double) -> Double {
        min(1, max(0, (p - a) / (b - a)))
    }

    private static func blinkNear(_ p: Double, _ at: Double, width: Double = 0.05) -> Double {
        1 - 0.94 * max(0, 1 - abs(p - at) / width)
    }

    private static func pose(_ change: (inout AvatarPose) -> Void) -> AvatarPose {
        AvatarPose.facing.with(change)
    }

    private static func looking(_ pose: inout AvatarPose, _ x: Double, _ y: Double) {
        pose.yaw += x * SolidTuning.turn
        pose.pitch += y * SolidTuning.turn
    }

    private static func keyframed(_ p: Double, _ frames: [(Double, AvatarPose)]) -> AvatarPose {
        var index = 0
        while index < frames.count - 2, p >= frames[index + 1].0 { index += 1 }
        let (a, from) = frames[index]
        let (b, to) = frames[index + 1]
        return from.blended(to: to, smooth(span(p, a, b)))
    }

    private static func clip(
        _ name: String, _ duration: Double, keeping turns: [Field] = [], _ raw: @escaping @Sendable (Double) -> AvatarPose
    ) -> LoadingClip {
        LoadingClip(name: name, duration: duration) { t in
            let weight = smooth(t / envelope) * smooth((duration - t) / envelope)
            let shown = raw(t)
            var result = AvatarPose.facing.blended(to: shown, weight)
            for turn in turns { result[keyPath: turn] = shown[keyPath: turn] }
            return result
        }
    }

    private static func wholeTurn(_ progress: Double, direction: Double = 1) -> Double {
        progress >= 1 ? 0 : direction * smooth(progress) * 360
    }

    static let spinAround = clip("spin-around", 2.4, keeping: [\.yaw]) { t in
        let p = cycle(t, 2.4)
        let k = span(p, 0, 0.6)
        return pose {
            $0.yaw = wholeTurn(k)
            $0.bodyScaleY = 1 - 0.05 * sin(k * Double.pi)
            $0.eyeOpen = blinkNear(p, 0.82)
        }
    }

    static let lookOrbit = clip("look-orbit", 3.6) { t in
        let a = t * tau / 1.8
        return pose { looking(&$0, cos(a) * 0.95, sin(a) * 0.95) }
    }

    static let readingLines = clip("reading-lines", 3) { t in
        let p = cycle(t, 3)
        let line = (p * 3).rounded(.down)
        let w = (p * 3).truncatingRemainder(dividingBy: 1)
        let x = w < 0.8 ? -0.85 + 1.7 * smooth(w / 0.8) : 0.85 - 1.7 * smooth((w - 0.8) / 0.2)
        return pose {
            looking(&$0, x, 0.4 - line * 0.45)
            $0.eyeDot = 0.35
            $0.eyeScale = 0.9
        }
    }

    static let hop = clip("hop", 1.8) { t in
        let p = cycle(t, 0.9)
        let air = span(p, 0.15, 0.85)
        let h = sin(air * Double.pi)
        let land = p < 0.15 ? 1 - p / 0.15 : p > 0.85 ? (p - 0.85) / 0.15 : 0
        return pose {
            $0.bodyY = -h * 0.16 * travel
            $0.bodyScaleY = 1 + 0.08 * h - 0.16 * land
            $0.bodyScaleX = 1 - 0.04 * h + 0.14 * land
            $0.eyeOpen = 1 - 0.5 * land
            looking(&$0, 0, 0.3 * h)
        }
    }

    static let ponderUp = clip("ponder-up", 3.2) { t in
        let p = cycle(t, 3.2)
        return pose {
            looking(&$0, -0.65, 0.7 + 0.06 * sin(t * 2))
            $0.eyeDot = 1
            $0.eyeScale = 0.85
            $0.bodyRotation = -7 * sin(t * tau / 3.2)
            $0.eyeOpen = min(blinkNear(p, 0.3, width: 0.06), blinkNear(p, 0.42, width: 0.06))
        }
    }

    static let dotChase = clip("dot-chase", 2.2, keeping: [\.pairSpin]) { t in
        let a = t * tau / 1.1
        return pose {
            $0.eyeDot = 1
            $0.eyeScale = 0.75
            $0.eyeSpread = 0.75
            $0.pairSpin = -(a * 180 / Double.pi).truncatingRemainder(dividingBy: 360)
            looking(&$0, 0.15 * cos(a), 0.15 * sin(a))
        }
    }

    static let jelly = clip("jelly", 2.4) { t in
        let w = sin(t * tau / 0.8)
        return pose {
            $0.bodyScaleX = 1 + 0.1 * w
            $0.bodyScaleY = 1 - 0.1 * w
            $0.eyeSpread = 1 + 0.12 * w
            $0.eyeScale = 1 - 0.06 * w
            looking(&$0, 0, -0.1)
        }
    }

    static let rollOver = clip("roll-over", 2.2, keeping: [\.bodyRotation]) { t in
        let k = span(cycle(t, 2.2), 0, 0.7)
        return pose {
            $0.bodyRotation = wholeTurn(k, direction: -1)
            $0.bodyX = 0.12 * sin(k * tau) * travel
            $0.eyeHappy = sin(k * Double.pi)
        }
    }

    static let frontFlip = clip("front-flip", 2.4, keeping: [\.pitch]) { t in
        let p = cycle(t, 2.4)
        let k = span(p, 0.1, 0.7)
        return pose {
            $0.pitch = wholeTurn(k)
            $0.bodyY = -0.14 * sin(k * Double.pi) * travel
            $0.bodyScaleY = p < 0.1 ? 1 - 0.12 * sin(p / 0.1 * Double.pi) : 1
            $0.eyeOpen = k > 0 && k < 1 ? 0.7 : 1
        }
    }

    static let peekaboo = clip("peekaboo", 3.2) { t in
        keyframed(cycle(t, 3.2), [
            (0, pose { _ in }), (0.25, pose { $0.yaw = 180 }), (0.55, pose { $0.yaw = 180 }),
            (0.7, pose { $0.eyeScale = 1.3; $0.bodyScaleY = 1.06 }), (0.82, pose { _ in }), (1, pose { _ in }),
        ])
    }

    static let dizzyEyes = clip("dizzy-eyes", 2.4, keeping: [\.eyeRoll]) { t in
        let a = t * tau / 0.7
        return pose {
            looking(&$0, 0.3 * cos(a), 0.3 * sin(a))
            $0.bodyRotation = -8 * sin(t * tau / 1.4)
            $0.eyeRoll = -((t * 360 / 0.8).truncatingRemainder(dividingBy: 360))
            $0.eyeDot = 0.3
            $0.bodyX = 0.04 * cos(a) * travel
        }
    }

    static let nodding = clip("nodding", 2.4) { t in
        let p = cycle(t, 0.6)
        return pose {
            looking(&$0, 0.5 * sin(t * tau / 4), -0.2 + 0.35 * abs(sin(p * Double.pi)))
            $0.eyeDot = 0.4
            $0.eyeOpen = 0.85
        }
    }

    static let glanceAround = clip("glance-around", 3.6) { t in
        func glance(_ x: Double, _ y: Double, _ change: (inout AvatarPose) -> Void = { _ in }) -> AvatarPose {
            pose { looking(&$0, x, y); change(&$0) }
        }
        return keyframed(cycle(t, 3.6), [
            (0, glance(-0.8, 0.2)), (0.2, glance(-0.8, 0.2)), (0.3, glance(0.8, 0.3)),
            (0.5, glance(0.8, 0.3)), (0.55, glance(0.8, 0.3) { $0.eyeOpen = 0.06 }),
            (0.6, glance(0.7, 0.3)), (0.7, glance(0, 0.85) { $0.eyeDot = 0.6 }),
            (0.88, glance(0, 0.85) { $0.eyeDot = 0.6 }), (1, glance(-0.8, 0.2)),
        ])
    }

    static let sleepyDroop = clip("sleepy-droop", 3.4) { t in
        let p = cycle(t, 3.4)
        let droop = smooth(span(p, 0, 0.6)) - smooth(span(p, 0.75, 0.85))
        return pose {
            looking(&$0, 0, -0.5 * droop)
            $0.bodyRotation = -10 * droop
            $0.eyeOpen = 1 - 0.85 * droop
            $0.bodyY = 0.04 * droop * travel
            $0.bodyScaleY = 1 - 0.04 * droop
        }
    }
}
