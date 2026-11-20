@testable import PalDesign
import SwiftUI
import Testing

@Suite("Chat row alignment")
struct ChatRowAlignmentTests {
    @Test("bot rows lead, user rows trail, system rows centre")
    func alignmentPerSender() {
        #expect(ChatMetrics.rowAlignment(for: .bot) == .leading)
        #expect(ChatMetrics.rowAlignment(for: .user) == .trailing)
        #expect(ChatMetrics.rowAlignment(for: .system) == .center)
    }

    @Test("a bubble column places a narrower child on its own side, never the middle")
    func bubbleColumnSide() {
        #expect(ChatMetrics.bubbleColumnAlignment(.leading) == .leading)
        #expect(ChatMetrics.bubbleColumnAlignment(.trailing) == .trailing)
    }
}
