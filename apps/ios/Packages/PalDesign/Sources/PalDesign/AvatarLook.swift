import CoreGraphics
import SwiftUI

struct AvatarLook: Equatable, Sendable, VectorArithmetic {
    var amount: Double
    var x: Double
    var y: Double

    static let zero = AvatarLook(amount: 0, x: 0, y: 0)

    var isIdle: Bool { amount == 0 }

    static func + (a: AvatarLook, b: AvatarLook) -> AvatarLook {
        AvatarLook(amount: a.amount + b.amount, x: a.x + b.x, y: a.y + b.y)
    }

    static func - (a: AvatarLook, b: AvatarLook) -> AvatarLook {
        AvatarLook(amount: a.amount - b.amount, x: a.x - b.x, y: a.y - b.y)
    }

    mutating func scale(by rhs: Double) {
        amount *= rhs
        x *= rhs
        y *= rhs
    }

    var magnitudeSquared: Double { amount * amount + x * x + y * y }

    static func toward(_ point: CGPoint, size: CGFloat, reach: CGFloat) -> AvatarLook {
        let half = Double(size) / 2
        let centre = half + Double(reach)
        let dx = Double(point.x) - centre
        let dy = Double(point.y) - centre
        let scale = 1 / (half * 1.25)
        var x = dx * scale
        var y = dy * scale
        let length = hypot(x, y)
        if length > 1 {
            x /= length
            y /= length
        }
        let distance = max(abs(dx), abs(dy))
        let approach = reach > 0 ? min(1, max(0, (distance - half) / Double(reach))) : 0
        return AvatarLook(amount: 1 - 0.5 * approach, x: x, y: y)
    }

    var released: AvatarLook { AvatarLook(amount: 0, x: x, y: y) }
}

extension AvatarRig {
    static let leanDegrees = 7.0
    static let lookReach = 0.28

    func posed(_ pose: AvatarPose, look: AvatarLook, reduceMotion: Bool) -> AvatarPose {
        guard !look.isIdle else { return pose }
        var result = pose
        guard !reduceMotion else { return result }
        let amount = look.amount
        result.front = pose.front + (1 - pose.front) * amount
        let upright = -restTilt * amount
        result.bodyRotation = pose.bodyRotation + upright + Self.leanDegrees * look.x * amount
        result.eyeRoll = pose.eyeRoll - upright
        return result
    }
}
