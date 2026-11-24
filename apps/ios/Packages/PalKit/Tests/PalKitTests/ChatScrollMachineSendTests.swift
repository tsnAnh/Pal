import Foundation
import PalChat
import Testing

private let container = 683.0
private let insetTop = 55.0
private let insetBottom = 92.0
private let atBottom = ChatScrollMachine.atBottomTolerance

private func geo(content: Double, distance: Double) -> ChatScrollGeometry {
    ChatScrollGeometry(
        offsetY: content - container - insetTop - distance,
        contentHeight: content,
        containerHeight: container,
        containerWidth: 900,
        insetTop: insetTop,
        insetBottom: insetBottom
    )
}

private func rows(_ count: Int) -> [String] { (0..<count).map { "row\($0)" } }

private struct MeasuredList {
    var machine = ChatScrollMachine()
    var content: Double
    var distance: Double

    init(rowCount: Int, content: Double, distance: Double = 0) {
        self.content = content
        self.distance = distance
        _ = machine.handle(.rowsChanged(rows(rowCount)))
        _ = machine.handle(.geometry(geo(content: content, distance: 0)))
        if distance > 0 { feed(distance: distance) }
    }

    var geometry: ChatScrollGeometry { geo(content: content, distance: distance) }
    var isAtBottom: Bool { distance <= atBottom }

    @discardableResult
    mutating func feed(content newContent: Double? = nil, distance newDistance: Double? = nil) -> ChatScrollMachine.Command {
        if let newContent {
            distance = max(0, distance + newContent - content)
            content = newContent
        }
        if let newDistance { distance = newDistance }
        return machine.handle(.geometry(geometry))
    }

    @discardableResult
    mutating func growWhileTheSystemAnchorLoses(to newContent: Double) -> ChatScrollMachine.Command {
        let command = feed(content: newContent)
        if case .scrollToBottom = command {
            distance = 0
            _ = machine.handle(.geometry(geometry))
        }
        return command
    }
}

@Suite("Chat scroll machine send")
struct ChatScrollMachineSendTests {
    @Test func sendWhilePinnedKeepsTheNewestRowAtTheBottomThroughTheReply() {
        var list = MeasuredList(rowCount: 160, content: 44_500)
        #expect(list.machine.handle(.send(animated: true)) == .none)
        _ = list.machine.handle(.rowsChanged(rows(161)))
        for content in [44_580.0, 44_653, 44_700, 44_760, 44_913, 45_050, 45_121, 45_230] {
            list.growWhileTheSystemAnchorLoses(to: content)
            #expect(list.isAtBottom, "content \(content): \(list.distance) pt from the bottom")
            #expect(list.machine.state == .pinnedToBottom)
            #expect(!list.machine.showsJumpButton)
        }
    }

    @Test func aGrowthStepTheAnchorMissedDoesNotTurnIntoReadingHistory() {
        var list = MeasuredList(rowCount: 160, content: 44_500)
        #expect(list.feed(content: 44_653) == .scrollToBottom(animated: false))
        #expect(list.distance == 153)
        #expect(list.feed() == .none)
        #expect(list.machine.state == .pinnedToBottom)
        #expect(!list.machine.showsJumpButton)
        #expect(list.feed(distance: 0) == .none)
        #expect(list.machine.state == .pinnedToBottom)
    }

    @Test func aRepairThatLandedShortIsRepairedAgainOnTheNextSizeChange() {
        var list = MeasuredList(rowCount: 160, content: 44_500)
        #expect(list.feed(content: 44_653) == .scrollToBottom(animated: false))
        #expect(list.feed(content: 44_700, distance: 40) == .scrollToBottom(animated: false))
        #expect(list.feed(content: 44_820, distance: 0) == .none)
        #expect(list.machine.state == .pinnedToBottom)
    }

    @Test func sendWhileReadingHistoryEndsAtTheBottomWhileTheRowsReResolve() {
        var list = MeasuredList(rowCount: 160, content: 44_844, distance: 785)
        #expect(list.machine.state == .readingHistory)
        _ = list.machine.handle(.rowsChanged(rows(163)))
        #expect(list.machine.unseen == 3)
        #expect(list.machine.handle(.send(animated: true)) == .scrollToBottom(animated: true))
        #expect(list.machine.state == .programmatic(.bottom))
        #expect(list.machine.unseen == 0)
        #expect(!list.machine.showsJumpButton)
        _ = list.machine.handle(.rowsChanged(rows(164)))
        #expect(list.machine.unseen == 0)
        #expect(list.feed(distance: 400) == .none)
        for content in [45_212.0, 44_700, 44_790, 44_752, 44_810, 44_760] {
            #expect(list.feed(content: content, distance: 105) == .scrollToBottom(animated: false), "content \(content)")
            #expect(list.machine.state == .programmatic(.bottom))
            #expect(!list.machine.showsJumpButton)
        }
        #expect(list.feed(distance: 0) == .none)
        #expect(list.machine.state == .pinnedToBottom)
        #expect(list.distance <= atBottom)
    }

    @Test func aJumpKeepsRepairingForAsLongAsTheContentKeepsMoving() {
        var list = MeasuredList(rowCount: 160, content: 44_844, distance: 785)
        _ = list.machine.handle(.jumpToNewest(animated: false))
        for step in 0..<60 {
            let command = list.feed(content: 44_900 + Double(step % 7) * 90 - Double(step % 3) * 40, distance: 105)
            #expect(command == .scrollToBottom(animated: false), "step \(step)")
        }
    }

    @Test func sendClearsUnseenAtTheMomentOfTheSendFromReadingHistory() {
        var list = MeasuredList(rowCount: 40, content: 9_000, distance: 500)
        _ = list.machine.handle(.rowsChanged(rows(43)))
        #expect(list.machine.unseen == 3)
        _ = list.machine.handle(.send(animated: false))
        #expect(list.machine.unseen == 0)
        #expect(!list.machine.showsJumpButton)
    }

    @Test func aUserScrollStopsTheRepairsAtOnce() {
        var list = MeasuredList(rowCount: 160, content: 44_844, distance: 785)
        _ = list.machine.handle(.send(animated: false))
        _ = list.machine.handle(.userScrollBegan)
        #expect(list.machine.state == .readingHistory)
        #expect(list.feed(content: 45_212, distance: 105) == .none)
        var pinned = MeasuredList(rowCount: 160, content: 44_500)
        _ = pinned.machine.handle(.userScrollBegan)
        #expect(pinned.feed(content: 44_653) == .none)
    }
}
