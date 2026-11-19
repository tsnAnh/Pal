import CoreGraphics
import Foundation

public enum SwipeReply {
    public static let threshold: CGFloat = 60
    public static let edgeInset: CGFloat = 28
    public static let minimumDistance: CGFloat = 12
    public static let horizontalDominance: CGFloat = 1.6

    public enum Decision: Equatable, Sendable {
        case undecided
        case tracking
        case rejected
    }

    public static func decide(startX: CGFloat, translation: CGSize) -> Decision {
        guard hypot(translation.width, translation.height) >= minimumDistance else { return .undecided }
        guard startX >= edgeInset, translation.width > 0 else { return .rejected }
        return translation.width >= horizontalDominance * abs(translation.height) ? .tracking : .rejected
    }

    public static func offset(for translation: CGFloat) -> CGFloat {
        min(max(translation, 0), threshold)
    }

    public static func progress(for translation: CGFloat) -> CGFloat {
        offset(for: translation) / threshold
    }

    public static func reachedThreshold(_ translation: CGFloat) -> Bool {
        translation >= threshold
    }
}
