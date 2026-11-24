import Foundation
import Testing

@testable import Pal

@MainActor
@Suite("Chat row heights")
struct ChatRowHeightsTests {
    private func user(_ delivery: BubbleDelivery) -> ChatRow {
        ChatRow(id: "u1", kind: .user(text: "hello", delivery: delivery))
    }

    @Test(arguments: [BubbleDelivery.sent, .waitingForConnection])
    func aDeliveryStateChangeOfAUserRowKeepsItsMeasuredHeight(next: BubbleDelivery) {
        let heights = ChatRowHeights()
        let sending = user(.sending)
        heights.measured(sending, height: 54, width: 600)
        #expect(heights.minHeight(for: sending, width: 600) == 54)
        #expect(heights.minHeight(for: user(next), width: 600) == 54)
    }

    @Test func aFailedUserRowGrowsAStatusLineSoItsHeightIsMeasuredAgain() {
        let heights = ChatRowHeights()
        heights.measured(user(.sending), height: 54, width: 600)
        #expect(heights.minHeight(for: user(.failed(submissionID: "s1")), width: 600) == nil)
    }

    @Test func aChangedTextForgetsTheHeight() {
        let heights = ChatRowHeights()
        heights.measured(user(.sent), height: 54, width: 600)
        let edited = ChatRow(id: "u1", kind: .user(text: "hello there, a longer line", delivery: .sent))
        #expect(heights.minHeight(for: edited, width: 600) == nil)
    }
}
