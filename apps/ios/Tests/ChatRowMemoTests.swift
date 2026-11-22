import Foundation
import Testing

@testable import HermesBots

@MainActor
@Suite("Chat row memos")
struct ChatRowMemoTests {
    @Test func theTimestampCacheAnswersLikeTheFormatter() {
        let now = Date()
        let calendar = Calendar.current
        let dates = [
            now,
            now.addingTimeInterval(-3_600),
            calendar.date(byAdding: .day, value: -1, to: now),
            calendar.date(byAdding: .day, value: -3, to: now),
            calendar.date(byAdding: .day, value: -30, to: now),
        ].compactMap { $0 }
        for date in dates {
            #expect(ChatTimestampCache.shared.label(for: date) == ChatTimestamp.label(for: date, now: now))
            #expect(ChatTimestampCache.shared.label(for: date) == ChatTimestamp.label(for: date, now: now))
        }
    }

    @Test(arguments: [
        "plain message",
        "",
        "> quoted line\n\nreply under the quote",
        "> first\n> second\n\nreply",
        "> not a quote block\nbut no blank line",
        "> only a quote\n\n",
    ])
    func cachedPartsEqualFreshParts(text: String) {
        let fresh = UserMessageParts(text)
        let cached = UserMessageParts.cached(text)
        #expect(cached == fresh)
        #expect(UserMessageParts.cached(text) == fresh)
        #expect(cached.attributedBody == AttributedString(fresh.body))
        #expect(cached.spoken == [fresh.quote, fresh.body.isEmpty ? nil : fresh.body].compactMap { $0 }.joined(separator: "\n"))
    }
}
