@testable import PalDesign
import Testing

@Suite("Bubble width rule")
struct BubbleWidthRuleTests {
    @Test("a column of any size yields the platform bubble width")
    func platformWidth() {
        #if os(macOS)
        #expect(ChatMetrics.bubbleWidth(inColumn: 2_000) == ChatMetrics.bubbleMaxWidth)
        #expect(ChatMetrics.bubbleWidth(inColumn: 300) == 300)
        #else
        #expect(ChatMetrics.bubbleWidth(inColumn: 400) == 400 * ChatMetrics.bubbleWidthFraction)
        #endif
    }
}
