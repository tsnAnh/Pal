import CoreGraphics
import Foundation

public enum SwipeReply {
    public static let threshold: CGFloat = 60
    public static let edgeInset: CGFloat = 28
    public static let horizontalDominance: CGFloat = 1.6

    public static func begins(startX: CGFloat, velocity: CGSize) -> Bool {
        startX >= edgeInset && velocity.width > 0 && velocity.width >= horizontalDominance * abs(velocity.height)
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
