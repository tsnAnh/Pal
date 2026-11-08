import Foundation

public enum AvatarMood: String, CaseIterable, Sendable {
    case idle
    case think
    case work
    case done

    public static let doneDuration: TimeInterval = AvatarMotion.doneDuration
}

struct AvatarPose: Equatable, Sendable {
    var front = 0.0
    var eyeX = 0.0
    var eyeY = 0.0
    var eyeRoll = 0.0
    var eyeSpread = 1.0
    var eyeScale = 1.0
    var eyeDot = 0.0
    var eyeHappy = 0.0
    var eyeOpen = 1.0
    var bodyX = 0.0
    var bodyY = 0.0
    var bodyScaleX = 1.0
    var bodyScaleY = 1.0
    var bodyRotation = 0.0
    var opacity = 1.0
    var dots = SIMD3<Double>(0, 0, 0)

    static let rest = AvatarPose()
    static let facing = AvatarPose(front: 1)

    static let geometry: [any WritableKeyPath<AvatarPose, Double> & Sendable] = [
        \.front, \.eyeX, \.eyeY, \.eyeRoll, \.eyeSpread, \.eyeScale,
        \.bodyX, \.bodyY, \.bodyScaleX, \.bodyScaleY, \.bodyRotation,
    ]
    static let appearance: [any WritableKeyPath<AvatarPose, Double> & Sendable] = [\.eyeDot, \.eyeHappy, \.eyeOpen, \.opacity]

    static let named: [String: any WritableKeyPath<AvatarPose, Double> & Sendable] = [
        "front": \.front, "eyeX": \.eyeX, "eyeY": \.eyeY, "eyeRoll": \.eyeRoll, "eyeSpread": \.eyeSpread,
        "eyeScale": \.eyeScale, "eyeDot": \.eyeDot, "eyeHappy": \.eyeHappy, "eyeOpen": \.eyeOpen,
        "bodyX": \.bodyX, "bodyY": \.bodyY, "bodyScaleX": \.bodyScaleX, "bodyScaleY": \.bodyScaleY,
        "bodyRotation": \.bodyRotation, "opacity": \.opacity,
    ]

    func with(_ change: (inout AvatarPose) -> Void) -> AvatarPose {
        var copy = self
        change(&copy)
        return copy
    }

    func blended(to target: AvatarPose, _ amount: Double) -> AvatarPose {
        var pose = self
        for key in Self.geometry + Self.appearance {
            pose[keyPath: key] = self[keyPath: key] + (target[keyPath: key] - self[keyPath: key]) * amount
        }
        pose.dots = dots + (target.dots - dots) * amount
        return pose
    }
}
