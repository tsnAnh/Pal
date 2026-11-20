import CoreGraphics

enum MessageChromePlacement: Equatable {
    case beside
    case insideBubble

    static let badgeSize = CGSize(width: 24, height: 24)
    static let besideBadgeOutset = CGSize(width: 13, height: -21)
    static let barGap: CGFloat = 8
    static let insetFromEdge: CGFloat = 6
    static let badgeRise: CGFloat = 12
    static let barDropBelowBadge: CGFloat = 4

    struct Frames: Equatable {
        let bar: CGRect
        let badge: CGRect?
    }

    struct Slot: Equatable {
        let side: MessageSide
        let preferred: MessageChromePlacement
    }

    struct Resolved: Equatable {
        let chrome: MessageChromePlacement
        let frames: Frames
    }

    func barTopInset(hasReaction: Bool) -> CGFloat {
        hasReaction ? Self.badgeSize.height - Self.badgeRise + Self.barDropBelowBadge : Self.insetFromEdge
    }

    var badgeOffset: CGSize {
        CGSize(width: -Self.insetFromEdge, height: -Self.badgeRise)
    }

    func insideFrames(bubble: CGRect, bar: CGSize, hasReaction: Bool, side: MessageSide = .assistant) -> Frames {
        let barX = side == .user ? bubble.minX + Self.insetFromEdge : bubble.maxX - Self.insetFromEdge - bar.width
        let badgeX = side == .user ? bubble.minX + Self.insetFromEdge : bubble.maxX - Self.insetFromEdge - Self.badgeSize.width
        let barFrame = CGRect(
            x: barX,
            y: bubble.minY + barTopInset(hasReaction: hasReaction),
            width: bar.width,
            height: bar.height
        )
        let badgeFrame = hasReaction
            ? CGRect(x: badgeX, y: bubble.minY - Self.badgeRise, width: Self.badgeSize.width, height: Self.badgeSize.height)
            : nil
        return Frames(bar: barFrame, badge: badgeFrame)
    }

    static func place(
        bubble: CGRect,
        region: CGRect,
        slot: Slot,
        bar: CGSize,
        hasReaction: Bool
    ) -> Resolved {
        if slot.preferred == .beside {
            let beside = besideFrames(bubble: bubble, side: slot.side, bar: bar, hasReaction: hasReaction)
            let spans = [beside.bar.minX, beside.bar.maxX] + (beside.badge.map { [$0.minX, $0.maxX] } ?? [])
            if spans.allSatisfy({ $0 >= region.minX && $0 <= region.maxX }) {
                return Resolved(chrome: .beside, frames: beside.keepingBar(inside: region))
            }
        }
        let inside = MessageChromePlacement.insideBubble.insideFrames(bubble: bubble, bar: bar, hasReaction: hasReaction, side: slot.side)
        return Resolved(chrome: .insideBubble, frames: inside.keepingBar(inside: region))
    }

    private static func besideFrames(bubble: CGRect, side: MessageSide, bar: CGSize, hasReaction: Bool) -> Frames {
        let barX = side == .user ? bubble.minX - barGap - bar.width : bubble.maxX + barGap
        let badgeX = side == .user
            ? bubble.minX - besideBadgeOutset.width
            : bubble.maxX - badgeSize.width + besideBadgeOutset.width
        let barFrame = CGRect(x: barX, y: bubble.midY - bar.height / 2, width: bar.width, height: bar.height)
        let badgeFrame = hasReaction
            ? CGRect(x: badgeX, y: bubble.minY + besideBadgeOutset.height, width: badgeSize.width, height: badgeSize.height)
            : nil
        return Frames(bar: barFrame, badge: badgeFrame)
    }
}

private extension MessageChromePlacement.Frames {
    func keepingBar(inside region: CGRect) -> MessageChromePlacement.Frames {
        let x = max(region.minX, min(bar.minX, region.maxX - bar.width))
        let y = max(region.minY, min(bar.minY, region.maxY - bar.height))
        return MessageChromePlacement.Frames(bar: CGRect(origin: CGPoint(x: x, y: y), size: bar.size), badge: badge)
    }
}
