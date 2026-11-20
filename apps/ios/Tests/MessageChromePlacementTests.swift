import CoreGraphics
import Testing

@testable import HermesBots

@Suite("Message chrome placement")
struct MessageChromePlacementTests {
    private let column = CGRect(x: 0, y: 0, width: 640, height: 2_000)
    private let bar = CGSize(width: 82, height: 32)

    private var tableBubble: CGRect { CGRect(x: 0, y: 100, width: column.width, height: 160) }

    @Test func aFullWidthBubbleKeepsTheBarAndBadgeInsideTheColumn() {
        for hasReaction in [false, true] {
            let frames = MessageChromePlacement.insideBubble.insideFrames(bubble: tableBubble, bar: bar, hasReaction: hasReaction)
            #expect(frames.bar.maxX <= column.maxX)
            #expect(frames.bar.minX >= column.minX)
            #expect(tableBubble.contains(frames.bar))
            if let badge = frames.badge {
                #expect(badge.maxX <= column.maxX)
                #expect(badge.minX >= column.minX)
            }
        }
    }

    @Test func theBesidePlacementWouldLeaveTheColumnOnAFullWidthBubble() {
        let besideBarMaxX = tableBubble.maxX + 8 + bar.width
        #expect(besideBarMaxX > column.maxX)
    }

    @Test func theBadgeNeverCoversTheBar() throws {
        let frames = MessageChromePlacement.insideBubble.insideFrames(bubble: tableBubble, bar: bar, hasReaction: true)
        let badge = try #require(frames.badge)
        #expect(!badge.intersects(frames.bar))
    }

    @Test func theBarSitsHigherWithoutAReaction() {
        let plain = MessageChromePlacement.insideBubble.barTopInset(hasReaction: false)
        let reacted = MessageChromePlacement.insideBubble.barTopInset(hasReaction: true)
        #expect(plain == MessageChromePlacement.insetFromEdge)
        #expect(reacted > plain)
    }

    @Test func theBadgeOffsetMatchesItsFrame() {
        let frames = MessageChromePlacement.insideBubble.insideFrames(bubble: tableBubble, bar: bar, hasReaction: true)
        let offset = MessageChromePlacement.insideBubble.badgeOffset
        let size = MessageChromePlacement.badgeSize
        #expect(frames.badge?.minX == tableBubble.maxX - size.width + offset.width)
        #expect(frames.badge?.minY == tableBubble.minY + offset.height)
    }
}
