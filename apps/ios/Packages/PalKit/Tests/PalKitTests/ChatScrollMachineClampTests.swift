import Foundation
import PalChat
import Testing

private let container = 683.0
private let insetTop = 55.0

private func geo(offset: Double, content: Double) -> ChatScrollGeometry {
    ChatScrollGeometry(
        offsetY: offset, contentHeight: content, containerHeight: container, containerWidth: 900,
        insetTop: insetTop, insetBottom: 92
    )
}

private func settled(content: Double, distance: Double = 0) -> ChatScrollGeometry {
    geo(offset: content - container - insetTop - distance, content: content)
}

@Suite("Chat scroll machine clamp")
struct ChatScrollMachineClampTests {
    @Test func overshootIsTheViewportPastTheContentEnd() {
        #expect(geo(offset: 18_900, content: 19_500).overshoot == 138)
        #expect(geo(offset: 18_900, content: 23_034).overshoot == 0)
        #expect(settled(content: 19_723).overshoot == 0)
    }

    @Test func contentShrinkingBelowTheOffsetClampsToTheEndWhilePinned() {
        var machine = ChatScrollMachine()
        _ = machine.handle(.geometry(settled(content: 54_984)))
        _ = machine.handle(.geometry(geo(offset: 18_900, content: 23_034)))
        #expect(machine.handle(.geometry(geo(offset: 18_900, content: 19_500))) == .clampToContent)
        #expect(machine.handle(.geometry(geo(offset: 18_900, content: 19_500))) == .clampToContent)
        #expect(machine.handle(.geometry(settled(content: 19_500))) == .none)
        #expect(machine.handle(.geometry(geo(offset: 18_900, content: 19_723))) == .scrollToBottom(animated: false))
    }

    @Test func contentShrinkingBelowTheOffsetClampsToTheEndWhileReadingHistory() {
        var machine = ChatScrollMachine()
        _ = machine.handle(.geometry(settled(content: 54_984)))
        _ = machine.handle(.geometry(settled(content: 54_984, distance: 400)))
        #expect(machine.state == .readingHistory)
        #expect(machine.handle(.geometry(geo(offset: 54_984 - container - insetTop - 400, content: 23_034))) == .clampToContent)
        #expect(machine.state == .readingHistory)
    }

    @Test func aUserScrollIsNeverClamped() {
        var machine = ChatScrollMachine()
        _ = machine.handle(.geometry(settled(content: 54_984)))
        _ = machine.handle(.userScrollBegan)
        #expect(machine.handle(.geometry(geo(offset: 18_900, content: 19_500))) == .none)
    }

    @Test func aShortListThatNeverShrankIsNotClamped() {
        var machine = ChatScrollMachine()
        #expect(machine.handle(.geometry(geo(offset: -insetTop, content: 300))) == .none)
        #expect(machine.handle(.geometry(geo(offset: -insetTop, content: 300))) == .none)
    }

    @Test func aListTallerThanTheViewportThatIsPastTheEndWithoutShrinkingIsClampedWhilePinned() {
        var machine = ChatScrollMachine()
        let content = 33_189.0
        _ = machine.handle(.geometry(geo(offset: content - container - insetTop + 92, content: content)))
        #expect(machine.handle(.geometry(geo(offset: content - container - insetTop + 92, content: content))) == .clampToContent)
        #expect(machine.handle(.geometry(settled(content: content))) == .none)
    }

    @Test func aListTallerThanTheViewportThatIsPastTheEndWithoutShrinkingIsNotClampedWhileTheUserScrolls() {
        var machine = ChatScrollMachine()
        let content = 33_189.0
        _ = machine.handle(.userScrollBegan)
        #expect(machine.handle(.geometry(geo(offset: content - container - insetTop + 92, content: content))) == .none)
    }
}
