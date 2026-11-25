import Foundation
import PalChat
import Testing

@Suite("Chat pinned short watch")
struct ChatPinnedShortWatchTests {
    private let limit = ChatPinnedShortWatch.limitMilliseconds

    @Test func aRepairThatLandsWithinTheLimitIsNotAnEpisode() {
        var watch = ChatPinnedShortWatch()
        watch.note(pinned: true, distance: 61, atMilliseconds: 1_890)
        #expect(watch.overdue(atMilliseconds: 1_890 + limit - 1) == nil)
        watch.note(pinned: true, distance: 0, atMilliseconds: 1_890 + limit - 1)
        #expect(watch.overdue(atMilliseconds: 1_890 + limit + 500) == nil)
        #expect(watch.episodes == 0)
    }

    @Test func aPinnedChatThatStaysShortPastTheLimitIsOneEpisodeWithItsDistanceAndTime() {
        var watch = ChatPinnedShortWatch()
        watch.note(pinned: true, distance: 61, atMilliseconds: 1_890)
        watch.note(pinned: true, distance: 57, atMilliseconds: 1_900)
        let episode = watch.overdue(atMilliseconds: 1_890 + limit + 1)
        #expect(episode == .init(distance: 57, milliseconds: Int(limit) + 1))
        #expect(watch.overdue(atMilliseconds: 3_000) == nil)
        #expect(watch.episodes == 1)
    }

    @Test func aChatThatIsNotPinnedIsNeverShort() {
        var watch = ChatPinnedShortWatch()
        watch.note(pinned: false, distance: 400, atMilliseconds: 0)
        #expect(!watch.isShort)
        #expect(watch.overdue(atMilliseconds: 10_000) == nil)
    }

    @Test func aNewShortStretchAfterTheBottomIsANewEpisode() {
        var watch = ChatPinnedShortWatch()
        watch.note(pinned: true, distance: 30, atMilliseconds: 0)
        _ = watch.overdue(atMilliseconds: limit + 1)
        watch.note(pinned: true, distance: 0, atMilliseconds: 500)
        watch.note(pinned: true, distance: 30, atMilliseconds: 600)
        _ = watch.overdue(atMilliseconds: 600 + limit + 1)
        #expect(watch.episodes == 2)
    }
}
