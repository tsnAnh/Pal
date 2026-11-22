import CoreGraphics
import Testing

@testable import Pal

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

    private let tracked = CGRect(x: 0, y: 0, width: 568, height: 400)

    private func resolve(
        _ frame: CGRect,
        side: MessageSide,
        preferred: MessageChromePlacement = .beside,
        hasReaction: Bool = false,
        region: CGRect? = nil
    ) -> MessageChromePlacement.Resolved {
        MessageChromePlacement.place(
            bubble: frame, region: region ?? tracked, slot: .init(side: side, preferred: preferred), bar: bar, hasReaction: hasReaction
        )
    }

    private func bubble(width: CGFloat, side: MessageSide) -> CGRect {
        CGRect(x: side == .user ? tracked.maxX - width : tracked.minX, y: 120, width: width, height: 60)
    }

    @Test(arguments: [MessageSide.assistant, .user], [120.0, 300, 478, 516, 568])
    func theBarAndBadgeStayInsideTheTrackedColumnAtEveryBubbleWidth(side: MessageSide, points: Double) throws {
        let width = CGFloat(points)
        for hasReaction in [false, true] {
            let resolved = resolve(bubble(width: width, side: side), side: side, hasReaction: hasReaction)
            #expect(tracked.contains(resolved.frames.bar))
            if hasReaction {
                let badge = try #require(resolved.frames.badge)
                #expect(badge.minX >= tracked.minX)
                #expect(badge.maxX <= tracked.maxX)
            }
            let room = tracked.width - width - MessageChromePlacement.barGap
            #expect(resolved.chrome == (room >= bar.width ? .beside : .insideBubble))
        }
    }

    @Test(arguments: [MessageSide.assistant, .user])
    func aBarBesideTheBubbleSitsInTheGutterAndNeverOverlapsIt(side: MessageSide) {
        let frame = bubble(width: 300, side: side)
        let resolved = resolve(frame, side: side)
        #expect(resolved.chrome == .beside)
        #expect(!resolved.frames.bar.intersects(frame))
        #expect(resolved.frames.bar.midY == frame.midY)
    }

    @Test(arguments: [MessageSide.assistant, .user])
    func aMaxWidthBubbleMovesTheBarIntoItsTopCorner(side: MessageSide) {
        let frame = bubble(width: 516, side: side)
        let resolved = resolve(frame, side: side)
        #expect(resolved.chrome == .insideBubble)
        #expect(frame.contains(resolved.frames.bar))
    }

    @Test func aShortBubbleKeepsTheBarInsideTheTrackedRowVertically() {
        let short = CGRect(x: 0, y: 0, width: 568, height: 36)
        let row = CGRect(x: 0, y: 0, width: 568, height: 36)
        let resolved = resolve(short, side: .assistant, hasReaction: true, region: row)
        #expect(row.contains(resolved.frames.bar))
    }

    @Test func theTableBubbleKeepsItsInsidePlacementAtFullWidth() {
        let table = CGRect(x: 0, y: 100, width: tracked.width, height: 160)
        let resolved = resolve(table, side: .assistant, preferred: .insideBubble, hasReaction: true)
        #expect(resolved.chrome == .insideBubble)
        #expect(tracked.contains(resolved.frames.bar))
        #expect(resolved.frames.badge.map { $0.maxX <= tracked.maxX && $0.minX >= tracked.minX } == true)
    }
}
