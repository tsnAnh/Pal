import SwiftUI

public enum PalMotion {
    public static let popScale: CGFloat = 0.9
    public static let popIn: Animation = .spring(duration: 0.25, bounce: 0)
    public static let popOutDuration: TimeInterval = 0.17

    public enum Settle {
        public static let collapse: Animation = .easeOut(duration: popOutDuration)
        public static var fade: AnyTransition { .opacity.animation(Pop.fade.animation) }

        public static func height(reduceMotion: Bool) -> Animation? {
            reduceMotion ? nil : collapse
        }
    }

    public enum Pop: Equatable, Sendable {
        case scaleFade
        case fade

        public init(reduceMotion: Bool) {
            self = reduceMotion ? .fade : .scaleFade
        }

        public var animation: Animation {
            switch self {
            case .scaleFade: PalMotion.popIn
            case .fade: .easeOut(duration: PalMotion.popOutDuration)
            }
        }

        public var transition: AnyTransition {
            switch self {
            case .scaleFade:
                .asymmetric(
                    insertion: .scale(scale: PalMotion.popScale).combined(with: .opacity),
                    removal: .scale(scale: PalMotion.popScale).combined(with: .opacity)
                        .animation(.easeIn(duration: PalMotion.popOutDuration))
                )
            case .fade:
                .opacity
            }
        }
    }
}
