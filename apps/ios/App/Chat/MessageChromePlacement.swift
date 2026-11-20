import CoreGraphics

enum MessageChromePlacement: Equatable {
    case beside
    case insideBubble

    static let badgeSize = CGSize(width: 24, height: 24)
    static let insetFromEdge: CGFloat = 6
    static let badgeRise: CGFloat = 12
    static let barDropBelowBadge: CGFloat = 4

    struct Frames: Equatable {
        let bar: CGRect
        let badge: CGRect?
    }

    func barTopInset(hasReaction: Bool) -> CGFloat {
        hasReaction ? Self.badgeSize.height - Self.badgeRise + Self.barDropBelowBadge : Self.insetFromEdge
    }

    var badgeOffset: CGSize {
        CGSize(width: -Self.insetFromEdge, height: -Self.badgeRise)
    }

    func insideFrames(bubble: CGRect, bar: CGSize, hasReaction: Bool) -> Frames {
        let barFrame = CGRect(
            x: bubble.maxX - Self.insetFromEdge - bar.width,
            y: bubble.minY + barTopInset(hasReaction: hasReaction),
            width: bar.width,
            height: bar.height
        )
        let badgeFrame = hasReaction
            ? CGRect(
                x: bubble.maxX - Self.insetFromEdge - Self.badgeSize.width,
                y: bubble.minY - Self.badgeRise,
                width: Self.badgeSize.width,
                height: Self.badgeSize.height
            )
            : nil
        return Frames(bar: barFrame, badge: badgeFrame)
    }
}
