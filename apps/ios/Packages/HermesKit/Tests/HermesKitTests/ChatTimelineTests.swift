import Foundation
import HermesChat
import Testing

@Suite("Chat timeline")
struct ChatTimelineTests {
    private static let base = Date(timeIntervalSince1970: 1_730_000_000)
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func user(_ id: String, at offset: TimeInterval?) -> TranscriptItem {
        item(id, .user(text: id, delivery: .sent), offset)
    }

    private func assistant(_ id: String, at offset: TimeInterval?) -> TranscriptItem {
        item(id, .assistant(text: id, reasoning: "", isStreaming: false), offset)
    }

    private func item(_ id: String, _ content: TranscriptItem.Content, _ offset: TimeInterval?) -> TranscriptItem {
        TranscriptItem(id: id, content: content, timestamp: offset.map { Self.base.addingTimeInterval($0) })
    }

    private func entries(_ items: [TranscriptItem], lastSeen: Date? = nil) -> [TimelineEntry] {
        ChatTimeline.entries(items: items, date: \.timestamp, lastSeen: lastSeen, calendar: calendar)
    }

    @Test func firstDatedRowAlwaysGetsASeparator() {
        let result = entries([user("a", at: 0), assistant("b", at: 5)])
        #expect(result.map { $0.separator != nil } == [true, false])
        #expect(result[0].separator == Self.base)
    }

    @Test func gapBelowThresholdKeepsRowsTogetherAndAtThresholdSplits() {
        let below = ChatTimeline.separatorGap - 1
        let result = entries([user("a", at: 0), assistant("b", at: below), assistant("c", at: below + ChatTimeline.separatorGap)])
        #expect(result.map { $0.separator != nil } == [true, false, true])
    }

    @Test func gapIsMeasuredFromThePreviousRowNotFromTheLastSeparator() {
        let step = ChatTimeline.separatorGap - 1
        let result = entries([user("a", at: 0), assistant("b", at: step), assistant("c", at: 2 * step)])
        #expect(result.map { $0.separator != nil } == [true, false, false])
    }

    @Test func aNewDayForcesASeparatorEvenWithoutAGap() {
        let midnight = calendar.startOfDay(for: Self.base).addingTimeInterval(86_400).timeIntervalSince(Self.base)
        let result = entries([user("a", at: midnight - 10), assistant("b", at: midnight + 10)])
        #expect(result.map { $0.separator != nil } == [true, true])
    }

    @Test func undatedRowsNeverGetASeparatorAndDoNotResetTheGap() {
        let result = entries([user("a", at: 0), assistant("b", at: nil), assistant("c", at: 30)])
        #expect(result.map { $0.separator != nil } == [true, false, false])
    }

    @Test func noLastSeenMeansNoNewDivider() {
        #expect(entries([user("a", at: 0), assistant("b", at: 60)]).allSatisfy { !$0.showsNewDivider })
    }

    @Test func dividerSitsAboveTheFirstUnreadReply() {
        let items = [user("a", at: 0), assistant("b", at: 60), user("c", at: 120), assistant("d", at: 4000), assistant("e", at: 4100)]
        let result = entries(items, lastSeen: Self.base.addingTimeInterval(200))
        #expect(result.map(\.showsNewDivider) == [false, false, false, true, false])
    }

    @Test func theUsersOwnMessagesAfterLastSeenDoNotStartTheDivider() {
        let items = [assistant("a", at: 0), user("b", at: 500), assistant("c", at: 600)]
        let result = entries(items, lastSeen: Self.base.addingTimeInterval(100))
        #expect(result.map(\.showsNewDivider) == [false, false, true])
    }

    @Test func nothingNewerThanLastSeenMeansNoDivider() {
        let result = entries([user("a", at: 0), assistant("b", at: 60)], lastSeen: Self.base.addingTimeInterval(60))
        #expect(result.allSatisfy { !$0.showsNewDivider })
    }

    @Test func dividerCanLeadTheTranscriptWhenEverythingIsUnread() {
        let result = entries([assistant("a", at: 100), assistant("b", at: 200)], lastSeen: Self.base)
        #expect(result.map(\.showsNewDivider) == [true, false])
    }

    @Test func botMessagesAndNotificationsCountAsUnread() {
        var bot = user("b", at: 500)
        bot.inbound = .botMessage(BotSender(name: "A", handle: "a"), body: "hi")
        var done = user("c", at: 600)
        done.inbound = .processCompletion
        #expect(entries([assistant("a", at: 0), bot, done], lastSeen: Self.base.addingTimeInterval(100)).map(\.showsNewDivider) == [false, true, false])
        #expect(entries([assistant("a", at: 0), done], lastSeen: Self.base.addingTimeInterval(100)).map(\.showsNewDivider) == [false, true])
    }
}
