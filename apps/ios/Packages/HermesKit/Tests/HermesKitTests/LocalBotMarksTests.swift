import Foundation
import HermesRoster
import Testing

@Suite("Local bot marks")
struct LocalBotMarksTests {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "bot-marks-\(UUID().uuidString)")! }

    @Test func unreadMarksPersistPerAccountAndClearOnRead() {
        let defaults = defaults()
        let mine = LocalBotMarks(defaults: defaults, account: "me")
        mine.markUnread("alpha")
        mine.markUnread("beta")
        mine.markUnread("alpha")
        #expect(LocalBotMarks(defaults: defaults, account: "me").unread == ["alpha", "beta"])
        #expect(LocalBotMarks(defaults: defaults, account: "other").unread.isEmpty)

        mine.markRead("alpha")
        mine.markRead("missing")
        #expect(mine.unread == ["beta"])
        mine.markRead("beta")
        #expect(defaults.object(forKey: LocalBotMarks.unreadKeyPrefix + "me") == nil)
    }

    @Test func pruningDropsMarksForBotsThatNoLongerExist() {
        let marks = LocalBotMarks(defaults: defaults(), account: "me")
        marks.markUnread("alpha")
        marks.markUnread("deleted")
        marks.prune(keeping: ["alpha", "beta"])
        #expect(marks.unread == ["alpha"])
    }
}
