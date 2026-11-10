import Foundation
import HermesChat
import Testing

@Suite("Transcript visibility")
struct TranscriptVisibilityTests {
    private func assistant(_ text: String) -> TranscriptItem {
        TranscriptItem(id: "a:\(text)", content: .assistant(text: text, reasoning: "", isStreaming: false))
    }

    private func user(_ text: String, inbound: InboundKind = .person) -> TranscriptItem {
        TranscriptItem(id: "u:\(text)", content: .user(text: text, delivery: .sent), inbound: inbound)
    }

    private func entries(_ items: [TranscriptItem]) -> [String] {
        ChatTimeline.entries(items: items, date: \.timestamp, lastSeen: nil).map(\.item.id)
    }

    @Test func aSilentOnlyReplyIsHiddenWhateverTheWhitespace() {
        #expect(entries([user("hi"), assistant("[SILENT]"), assistant("  [SILENT]\n")]) == ["u:hi"])
    }

    @Test func proseQuotingTheMarkerStaysVisible() {
        let quoting = assistant("Nothing new, so [SILENT] is what I would say.")
        #expect(entries([quoting]) == [quoting.id])
    }

    @Test func processNoticesAndBotChatCronjobTurnsAreHidden() {
        let process = user("[IMPORTANT: Background process 1 finished]", inbound: .processCompletion)
        let cron = user("[Cronjob \"digest\"] run now")
        let real = user("hello")
        #expect(entries([process, cron, real]) == [real.id])
    }

    @Test func visibleKeepsOnlyWhatARealChatShows() {
        let items = [user("q"), assistant("real answer"), user("[Cronjob \"digest\"] go"), assistant("[SILENT]")]
        #expect(TranscriptVisibility.visible(items).map(\.id) == ["u:q", "a:real answer"])
        #expect(TranscriptVisibility.visible(items, botChat: false).map(\.id) == ["u:q", "a:real answer", "u:[Cronjob \"digest\"] go"])
    }
}
