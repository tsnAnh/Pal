import CoreGraphics
import Foundation
import PalChat
import Testing

@Suite("Message actions core")
struct MessageActionsCoreTests {
    private func table() -> MarkdownTable {
        MarkdownTable(
            alignments: [.leading, .trailing, .center],
            header: [AttributedString("Run"), AttributedString("Score"), AttributedString("Note")],
            rows: [
                [AttributedString("A"), AttributedString("6.5"), AttributedString("a|b")],
                [AttributedString("B"), AttributedString("9.0"), AttributedString("two\nlines\tx")],
            ]
        )
    }

    @Test func plainMessageOffersReplyUnreadCopyShareSpeak() {
        let plan = MessageActionPlan(isOwnFailed: false, hasTable: false, isChatUnread: false, offersSelectText: true)
        #expect(plan.groups == [[.reply, .markUnread], [.copy, .selectText], [.share, .speak]])
    }

    @Test func unreadChatOffersMarkAsRead() {
        let plan = MessageActionPlan(isOwnFailed: false, hasTable: false, isChatUnread: true, offersSelectText: false)
        #expect(plan.groups.first == [.reply, .markRead])
        #expect(!plan.actions.contains(.selectText))
    }

    @Test func tableMessageAddsCopyTableAndNothingElseDoes() {
        let withTable = MessageActionPlan(isOwnFailed: false, hasTable: true, isChatUnread: false, offersSelectText: true)
        let without = MessageActionPlan(isOwnFailed: false, hasTable: false, isChatUnread: false, offersSelectText: true)
        #expect(withTable.actions.contains(.copyTable))
        #expect(!without.actions.contains(.copyTable))
        #expect(!withTable.actions.contains(.retry))
    }

    @Test func retryAppearsOnlyOnTheOwnersFailedMessage() {
        let failed = MessageActionPlan(isOwnFailed: true, hasTable: false, isChatUnread: false, offersSelectText: true)
        let sent = MessageActionPlan(isOwnFailed: false, hasTable: false, isChatUnread: false, offersSelectText: true)
        #expect(failed.groups == [[.retry], [.copy, .selectText]])
        #expect(!sent.actions.contains(.retry))
        #expect(!failed.actions.contains(.reply))
    }

    @Test func reactionChoicesKeepTheApprovedOrder() {
        #expect(ReactionCatalog.quick == ["👍", "👎", "❤️", "😂", "🎉", "😮", "🔥", "👀", "🙏", "😢", "💯"])
        #expect(ReactionCatalog.all.prefix(11).map(\.symbol) == ReactionCatalog.quick)
        #expect(Set(ReactionCatalog.all.map(\.symbol)).count == ReactionCatalog.all.count)
    }

    @Test func emojiSearchMatchesKeywordsAndSymbols() {
        #expect(ReactionCatalog.search("").count == ReactionCatalog.all.count)
        #expect(ReactionCatalog.search("rocket").map(\.symbol) == ["🚀"])
        #expect(ReactionCatalog.search("  LOVE ").map(\.symbol) == ["❤️", "😍"])
        #expect(ReactionCatalog.search("🔥").map(\.symbol) == ["🔥"])
        #expect(ReactionCatalog.search("zzzzzz").isEmpty)
    }

    @Test func tableCopiesAsMarkdownWithAlignmentAndEscapedPipes() {
        #expect(table().markdown == """
        | Run | Score | Note |
        | --- | ---: | :---: |
        | A | 6.5 | a\\|b |
        | B | 9.0 | two lines x |
        """)
    }

    @Test func tableCopiesAsTabSeparatedValues() {
        #expect(table().tsv == "Run\tScore\tNote\nA\t6.5\ta|b\nB\t9.0\ttwo lines x")
    }

    @Test func swipeStartsOnlyFromAMostlyHorizontalRightwardDragAwayFromTheEdge() {
        #expect(SwipeReply.decide(startX: 100, translation: CGSize(width: 4, height: 2)) == .undecided)
        #expect(SwipeReply.decide(startX: 100, translation: CGSize(width: 30, height: 8)) == .tracking)
        #expect(SwipeReply.decide(startX: 100, translation: CGSize(width: 30, height: 30)) == .rejected)
        #expect(SwipeReply.decide(startX: 100, translation: CGSize(width: 4, height: 40)) == .rejected)
        #expect(SwipeReply.decide(startX: 100, translation: CGSize(width: -30, height: 2)) == .rejected)
        #expect(SwipeReply.decide(startX: 10, translation: CGSize(width: 40, height: 0)) == .rejected)
    }

    @Test func swipeOffsetFollowsTheFingerUpToTheThreshold() {
        #expect(SwipeReply.offset(for: -20) == 0)
        #expect(SwipeReply.offset(for: 25) == 25)
        #expect(SwipeReply.offset(for: 200) == SwipeReply.threshold)
        #expect(SwipeReply.progress(for: 30) == 0.5)
        #expect(!SwipeReply.reachedThreshold(59.9))
        #expect(SwipeReply.reachedThreshold(60))
    }
}
