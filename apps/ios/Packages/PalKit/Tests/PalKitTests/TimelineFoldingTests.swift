import Foundation
@testable import PalChat
import PalProtocol
import Testing

struct TimelineFoldingTests {
    private func link(anchor: String, covered: [String]) -> BotThreadLink {
        BotThreadLink(
            anchorUID: anchor,
            threadID: "bt_x",
            exchangeID: "out:aa",
            kind: .messaged,
            counterpart: BotThreadParticipant(key: "local:beta", isSelf: false, localProfile: "beta", displayName: "Beta", handle: "beta"),
            coveredUIDs: covered,
            count: covered.count
        )
    }

    private func timeline(_ ids: [String]) -> Timeline {
        var timeline = Timeline()
        let entries = ids.map { TimelineEntryWire(id: $0, role: .assistant, text: $0) }
        timeline.mergeNewest(TimelinePageWire(entries: entries, older: nil, revision: "r"))
        return timeline
    }

    @Test func aFoldSitsAtItsEarliestMemberAndKeepsThatRowKey() {
        let timeline = timeline(["a", "call", "b", "ack", "c"])
        let plain = timeline.rows(links: [])
        let folded = timeline.rows(links: [link(anchor: "ack", covered: ["call", "ack"])])
        #expect(folded.map(\.item.id) == ["a", "bot-thread:ack", "b", "c"])
        #expect(folded[1].id == plain[1].id)
        #expect(folded.map(\.id) == [plain[0].id, plain[1].id, plain[2].id, plain[4].id])
    }

    @Test func aLateAnchorJoinsTheFoldWithoutMovingIt() {
        let timeline = timeline(["a", "call", "b"])
        let before = timeline.rows(links: [link(anchor: "ack", covered: ["call", "ack"])])
        var grown = timeline
        grown.mergeNewest(TimelinePageWire(
            entries: ["a", "call", "b", "ack"].map { TimelineEntryWire(id: $0, role: .assistant, text: $0) },
            older: nil,
            revision: "r2"
        ))
        let after = grown.rows(links: [link(anchor: "ack", covered: ["call", "ack"])])
        #expect(before.map(\.id) == after.map(\.id))
        #expect(after.map(\.item.id) == ["a", "bot-thread:ack", "b"])
    }
}
