@testable import PalChat
import PalProtocol
import Testing

@Suite("Chat row identity")
struct ChatRowIdentityTests {
    private func row(_ key: UInt64, item id: String) -> ChatTimelineRow {
        ChatTimelineRow(
            id: RowKey(value: key),
            item: TranscriptItem(id: id, content: .user(text: id, delivery: .sent), timestamp: nil),
            entryID: nil,
            rowID: nil
        )
    }

    private func key(_ value: UInt64) -> RowKey { RowKey(value: value) }

    @Test func aPendingSubmissionKeepsItsIDWhenTheTimelineRowArrives() {
        var identity = ChatRowIdentity()
        let outbox: Set<String> = ["submission:42"]
        let pending = identity.ids(for: [row(1, item: "m1"), row(2, item: "submission:42")], outboxIDs: outbox, forwarded: [:])
        #expect(pending == ["row-1", "submission:42"])
        let arrived = identity.ids(for: [row(1, item: "m1"), row(7, item: "submission:42")], outboxIDs: outbox, forwarded: [:])
        #expect(arrived == ["row-1", "submission:42"])
    }

    @Test func aLiveRowForwardedToAStoredRowKeepsTheLiveID() {
        var identity = ChatRowIdentity()
        #expect(identity.ids(for: [row(5, item: "live")], outboxIDs: [], forwarded: [:]) == ["row-5"])
        #expect(identity.ids(for: [row(9, item: "stored")], outboxIDs: [], forwarded: [key(5): key(9)]) == ["row-5"])
    }

    @Test func aForwardChainKeepsTheEarliestLiveID() {
        var identity = ChatRowIdentity()
        _ = identity.ids(for: [row(5, item: "live")], outboxIDs: [], forwarded: [:])
        _ = identity.ids(for: [row(9, item: "stored")], outboxIDs: [], forwarded: [key(5): key(9)])
        let chained = identity.ids(for: [row(12, item: "stored")], outboxIDs: [], forwarded: [key(5): key(9), key(9): key(12)])
        #expect(chained == ["row-5"])
    }

    @Test func aChainResolvesInOneStepWithoutPriorHistory() {
        var identity = ChatRowIdentity()
        let ids = identity.ids(for: [row(12, item: "stored")], outboxIDs: [], forwarded: [key(5): key(9), key(9): key(12)])
        #expect(ids == ["row-5"])
    }

    @Test func aDuplicateFallsBackToItsOwnKeyDescription() {
        var identity = ChatRowIdentity()
        let ids = identity.ids(
            for: [row(5, item: "live"), row(9, item: "stored")],
            outboxIDs: [],
            forwarded: [key(5): key(9)]
        )
        #expect(ids == ["row-5", "row-9"])
    }

    @Test func idsAreStableAcrossRepeatedCalls() {
        var identity = ChatRowIdentity()
        let rows = [row(1, item: "a"), row(2, item: "submission:1"), row(3, item: "c")]
        let first = identity.ids(for: rows, outboxIDs: ["submission:1"], forwarded: [:])
        let second = identity.ids(for: rows, outboxIDs: [], forwarded: [:])
        let third = identity.ids(for: rows, outboxIDs: ["submission:1"], forwarded: [:])
        #expect(first == second)
        #expect(second == third)
    }
}
