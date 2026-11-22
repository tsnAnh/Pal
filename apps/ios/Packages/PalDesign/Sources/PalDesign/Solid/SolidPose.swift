import Foundation

struct SolidPose: Equatable, Sendable {
    var yaw = 0.0
    var pitch = 0.0
    var roll = 0.0
    var eyeRoll = 0.0
    var pairSpin = 0.0
    var eyeScale = 1.0
    var eyeSpread = 1.0
    var eyeDot = 0.0
    var eyeHappy = 0.0
    var eyeOpen = 1.0
    var bodyX = 0.0
    var bodyY = 0.0
    var bodyScaleX = 1.0
    var bodyScaleY = 1.0
    var opacity = 1.0
    var dots = SIMD3<Double>(0, 0, 0)

    static func resolve(pose: AvatarPose, look: AvatarLook, restTilt: Double, restTurn: RestTurn = .full, reduceMotion: Bool) -> SolidPose {
        let amount = reduceMotion ? 0 : look.amount
        let facing = pose.front + (1 - pose.front) * amount
        let rest = 1 - facing
        let lookX = reduceMotion ? 0 : look.x * amount
        let lookY = reduceMotion ? 0 : look.y * amount
        let turn = SolidTuning.turn
        let reach = SolidTuning.eyeReach
        let restYaw = rest * SolidTuning.restLook.x * turn * restTurn.look
        let restPitch = rest * SolidTuning.restLook.y * turn * restTurn.look
        return SolidPose(
            yaw: restYaw + degrees(asin(clamp(reach * pose.eyeX))) + pose.yaw + lookX * turn,
            pitch: restPitch - degrees(asin(clamp(reach * pose.eyeY))) + pose.pitch - lookY * turn,
            roll: pose.bodyRotation + restTilt * restTurn.tilt * rest,
            eyeRoll: SolidTuning.restEyeSlant * rest - pose.eyeRoll,
            pairSpin: -pose.pairSpin,
            eyeScale: pose.eyeScale,
            eyeSpread: pose.eyeSpread,
            eyeDot: pose.eyeDot,
            eyeHappy: pose.eyeHappy,
            eyeOpen: pose.eyeOpen,
            bodyX: pose.bodyX,
            bodyY: pose.bodyY,
            bodyScaleX: pose.bodyScaleX,
            bodyScaleY: pose.bodyScaleY,
            opacity: pose.opacity,
            dots: pose.dots
        )
    }

    private static func clamp(_ value: Double) -> Double { min(1, max(-1, value)) }
    private static func degrees(_ radians: Double) -> Double { radians * 180 / Double.pi }
}
