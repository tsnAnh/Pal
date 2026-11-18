import Foundation

struct AvatarActivity: Equatable, Sendable {
    static let restingBlinkMinimumSize: CGFloat = 48
    static let loopInterval: TimeInterval = 1.0 / 30
    static let reducedInterval: TimeInterval = 1.0 / 20

    let mood: AvatarMood
    let size: CGFloat
    let animated: Bool
    let reduceMotion: Bool

    var blinksAtRest: Bool { !reduceMotion && size >= Self.restingBlinkMinimumSize }

    var tracksPointer: Bool { animated }

    var frameInterval: TimeInterval { reduceMotion ? Self.reducedInterval : Self.loopInterval }

    func ticks(settling: Bool) -> Bool {
        animated && (mood != .idle || blinksAtRest || settling)
    }
}
