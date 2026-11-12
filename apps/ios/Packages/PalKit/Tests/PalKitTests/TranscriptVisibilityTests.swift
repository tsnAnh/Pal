import Foundation
import PalChat
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

    @Test func processNoticesStayVisibleAndBotChatCronjobTurnsAreHidden() {
        let process = user("[IMPORTANT: Background process 1 finished]", inbound: .processCompletion)
        let cron = user("[Cronjob \"digest\"] run now")
        let real = user("hello")
        #expect(entries([process, cron, real]) == [process.id, real.id])
    }

    @Test func visibleKeepsOnlyWhatARealChatShows() {
        let items = [user("q"), assistant("real answer"), user("[Cronjob \"digest\"] go"), assistant("[SILENT]")]
        #expect(TranscriptVisibility.visible(items).map(\.id) == ["u:q", "a:real answer"])
        #expect(TranscriptVisibility.visible(items, botChat: false).map(\.id) == ["u:q", "a:real answer", "u:[Cronjob \"digest\"] go"])
    }

    private static let ok = "[IMPORTANT: Background process proc_a completed normally (exit code 0).\nCommand: date\nOutput:\nx]"
    private static let failed = "[IMPORTANT: Background process proc_b exited (exit code 2).\nCommand: make\nOutput:\nboom]"
    private static let watch = "[IMPORTANT: Background process proc_c matched watch pattern \"error\".\nCommand: tail\nMatched output:\nerror]"

    private func notice(_ text: String) -> TranscriptItem {
        user(text, inbound: .processCompletion)
    }

    @Test func successfulBackgroundNoticeIsHiddenButStillInTheModel() {
        let items = [user("hi"), notice(Self.ok), assistant("done")]
        #expect(entries(items) == ["u:hi", "a:done"])
        #expect(items.count == 3)
    }

    @Test func failedWatchAndUnparsedNoticesStayVisible() {
        let items = [notice(Self.failed), notice(Self.watch), notice("[IMPORTANT: Background process p done]")]
        #expect(entries(items).count == 3)
    }

    @Test func groupOfOnlySuccessesIsHiddenAndMixedGroupStaysVisible() {
        let allOk = "[IMPORTANT: 2 background process results arrived while busy.]\n\n\(Self.ok)\n\n\(Self.ok)"
        let mixed = "[IMPORTANT: 2 background process results arrived while busy.]\n\n\(Self.ok)\n\n\(Self.failed)"
        #expect(entries([notice(allOk)]).isEmpty)
        #expect(entries([notice(mixed)]).count == 1)
    }

    @Test func outputQuotingSuccessDoesNotHideAFailure() {
        let sneaky = "[IMPORTANT: Background process p exited (exit code 1).\nOutput:\nBackground process q completed normally (exit code 0)]"
        #expect(entries([notice(sneaky)]).count == 1)
    }
}
