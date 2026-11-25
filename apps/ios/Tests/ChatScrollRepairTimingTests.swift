import PalChat
import SwiftUI
import Testing

@testable import Pal

@MainActor
@Suite("Chat scroll repair timing")
struct ChatScrollRepairTimingTests {
    private static let content = 5_000.0
    private static let window = 800.0

    private func geometry(inset: Double, offset: Double? = nil) -> ScrollGeometry {
        let container = Self.window - inset
        return ScrollGeometry(
            contentOffset: CGPoint(x: 0, y: offset ?? Self.content - container),
            contentSize: CGSize(width: 600, height: Self.content),
            contentInsets: EdgeInsets(top: 0, leading: 0, bottom: inset, trailing: 0),
            containerSize: CGSize(width: 600, height: container)
        )
    }

    private func pinnedAtBottom() async throws -> ChatScrollController {
        let scroll = ChatScrollController()
        scroll.observe(geometry(inset: 92))
        try await Task.sleep(for: ChatScrollController.resizeSettle + .milliseconds(150))
        return scroll
    }

    @Test("a composer that grows under a pinned list is repaired in the same pass, not on a later turn")
    func insetGrowthIsRepairedAtOnce() async throws {
        let scroll = try await pinnedAtBottom()
        try #require(scroll.position.edge == nil)
        scroll.observe(geometry(inset: 119, offset: Self.content - (Self.window - 92)))
        #expect(scroll.position.edge == .bottom)
    }

    @Test("the newest row growing under a pinned list is followed in the same pass")
    func newestRowGrowthIsFollowedAtOnce() async throws {
        let scroll = try await pinnedAtBottom()
        try #require(scroll.position.edge == nil)
        let row = ChatRow(id: "s1", kind: .user(text: "hello", delivery: .sent))
        _ = scroll.renderPlan(of: [row], persisted: nil, textScale: "")
        scroll.rowLaidOut("s1", frame: CGRect(x: 0, y: 4_900, width: 600, height: 100))
        try #require(scroll.position.edge == nil)
        scroll.rowLaidOut("s1", frame: CGRect(x: 0, y: 4_900, width: 600, height: 123))
        #expect(scroll.position.edge == .bottom)
    }
}
