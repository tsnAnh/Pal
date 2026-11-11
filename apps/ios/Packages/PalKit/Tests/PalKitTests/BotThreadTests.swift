import Foundation
import PalChat
import PalProtocol
import Testing

@Suite("Bot threads")
struct BotThreadTests {
    private static let linksJSON = """
    {"links": [{"anchor_uid": "ff9a", "count": 2, "kind": "messaged", "thread_id": "bt_02b7b858fd6d010b5623",
      "exchange_id": "out:a555420eb497383e17aa5eb8ae220eac3ea06a3b9c57fbd944666e93c4f9faa3",
      "covered_uids": ["b790", "ff9a"],
      "counterpart": {"key": "local:beta", "is_self": false, "local_profile": "beta", "display_name": "Beta",
        "handle": "beta", "avatar": {"has_asset": false, "ui_meta": {"description": "beta bot", "title": "Beta"}}}}],
     "truncated": false}
    """

    private static let pageJSON = """
    {"thread_id": "bt_02b7b858fd6d010b5623", "coverage": "both_sides", "focus_index": 1, "rev": 2,
     "before": 7, "after": null, "history_since": "2026-11-07T23:34:49.666+00:00", "read_only": true,
     "participants": [
       {"key": "local:alpha", "is_self": true, "local_profile": "alpha", "display_name": "Alpha", "handle": "alpha",
        "avatar": {"has_asset": false, "ui_meta": null}},
       {"key": "relay:xyz", "is_self": false, "local_profile": null, "display_name": "Remote", "handle": "remote",
        "avatar": {"has_asset": false}}],
     "messages": [
       {"id": "btm_8", "exchange_id": "out:aa", "sender_key": "local:alpha", "text": "status?",
        "at": "2026-11-07T23:34:49.666+00:00", "part": "message", "status": "answered", "status_text": null},
       {"id": "btm_9", "exchange_id": "out:aa", "sender_key": "relay:xyz", "text": "green",
        "at": "2026-11-07T23:34:50.029Z", "part": "reply", "status": "answered"}]}
    """

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    private func link(anchor: String, covered: [String], count: Int = 1, kind: BotThreadLink.Kind = .messaged) -> BotThreadLink {
        BotThreadLink(
            anchorUID: anchor,
            threadID: "bt_x",
            exchangeID: "out:aa",
            kind: kind,
            counterpart: BotThreadParticipant(key: "local:beta", isSelf: false, localProfile: "beta", displayName: "Beta", handle: "beta"),
            coveredUIDs: covered,
            count: count
        )
    }

    private func item(_ id: String, uid: String?, offset: TimeInterval = 0) -> TranscriptItem {
        TranscriptItem(
            id: id,
            content: .assistant(text: id, reasoning: "", isStreaming: false),
            timestamp: Date(timeIntervalSince1970: 1_730_000_000 + offset),
            uid: uid
        )
    }

    @Test func linksDecodeTheCanonicalWireShape() throws {
        let result = try decode(BotThreadLinksResult.self, Self.linksJSON)
        let link = try #require(result.links.first)
        #expect(link.kind == .messaged)
        #expect(link.count == 2)
        #expect(link.coveredUIDs == ["b790", "ff9a"])
        #expect(link.counterpart.localProfile == "beta")
        #expect(link.counterpart.avatar.uiMeta?["title"]?.stringValue == "Beta")
        #expect(!result.truncated)
    }

    @Test func pageDecodesFractionalAndWholeSecondTimestampsAndRemoteParticipants() throws {
        let page = try decode(BotThreadPage.self, Self.pageJSON)
        #expect(page.messages.map(\.id) == ["btm_8", "btm_9"])
        #expect(page.messages[1].at.timeIntervalSince(page.messages[0].at) > 0)
        #expect(page.participants[1].localProfile == nil)
        #expect(page.messages[1].statusText == nil)
        #expect(page.messages[0].sequence == 8)
        #expect(!page.isOwnSideOnly)
    }

    @Test func malformedTimestampFailsDecoding() {
        let broken = Self.pageJSON.replacingOccurrences(of: "2026-11-07T23:34:50.029Z", with: "yesterday")
        #expect(throws: DecodingError.self) { try decode(BotThreadPage.self, broken) }
    }

    @Test func messageUIDDecodesFromTheTranscriptRow() throws {
        let row = try decode(WireMessage.self, #"{"role":"user","text":"hi","message_uid":"abc"}"#)
        #expect(row.messageUID == "abc")
        let plain = try decode(WireMessage.self, #"{"role":"user","text":"hi"}"#)
        #expect(plain.messageUID == nil)
    }

    @Test func foldingReplacesCoveredRowsWithOneRowAtTheAnchor() {
        let items = [
            item("a", uid: "u0"), item("call", uid: "b790"), item("ack", uid: "ff9a"), item("b", uid: "u9"),
        ]
        let folded = BotThreadFolding.fold(items, links: [link(anchor: "ff9a", covered: ["b790", "ff9a"], count: 2)])
        #expect(folded.map(\.id) == ["a", "bot-thread:ff9a", "b"])
        guard case .botThread(let placed) = folded[1].content else { Issue.record("not a link row"); return }
        #expect(placed.count == 2)
        #expect(folded[1].timestamp == items[2].timestamp)
    }

    @Test func foldingKeepsRowsWithoutUidsAndWithoutLinks() {
        let items = [item("a", uid: nil), item("b", uid: "u1")]
        #expect(BotThreadFolding.fold(items, links: []) == items)
        #expect(BotThreadFolding.fold(items, links: [link(anchor: "zzz", covered: ["zzz"])]) == items)
    }

    @Test func foldingFallsBackToTheFirstCoveredRowWhenTheAnchorIsAbsent() {
        let items = [item("a", uid: "x1"), item("b", uid: "x2"), item("c", uid: "u9")]
        let folded = BotThreadFolding.fold(items, links: [link(anchor: "gone", covered: ["x1", "x2"], count: 2)])
        #expect(folded.map(\.id) == ["bot-thread:gone", "c"])
    }

    @Test func foldingHandlesSeveralLinksAndNeverDuplicatesARow() {
        let items = [item("a", uid: "a1"), item("h", uid: "h1"), item("b", uid: "b1"), item("b2", uid: "b2")]
        let folded = BotThreadFolding.fold(items, links: [
            link(anchor: "a1", covered: ["a1"]),
            link(anchor: "b1", covered: ["b1", "b2"], kind: .messageFrom),
        ])
        #expect(folded.map(\.id) == ["bot-thread:a1", "h", "bot-thread:b1"])
    }

    @Test func messageFromLinksCountAsIncomingForTheUnreadDivider() {
        let items = [
            item("old", uid: "o", offset: 0),
            TranscriptItem(
                id: "bot-thread:in",
                content: .botThread(link(anchor: "in", covered: ["in"], kind: .messageFrom)),
                timestamp: Date(timeIntervalSince1970: 1_730_000_100)
            ),
        ]
        let entries = ChatTimeline.entries(items: items, date: \.timestamp, lastSeen: Date(timeIntervalSince1970: 1_730_000_050))
        #expect(entries.map(\.showsNewDivider) == [false, true])
    }

    @Test func timelineOpensAtTheFocusedMessageAndMergesPages() throws {
        let page = try decode(BotThreadPage.self, Self.pageJSON)
        var timeline = BotThreadTimeline(threadID: page.threadID)
        timeline.apply(initial: page)
        #expect(timeline.focusMessageID == "btm_9")
        #expect(timeline.hasOlder)
        #expect(!timeline.hasNewer)

        let older = try decode(BotThreadPage.self, Self.pageJSON
            .replacingOccurrences(of: "btm_8", with: "btm_6")
            .replacingOccurrences(of: "btm_9", with: "btm_7")
            .replacingOccurrences(of: "2026-11-07T23:34:49.666+00:00\", \"part\"", with: "2026-11-07T23:00:00.000+00:00\", \"part\"")
            .replacingOccurrences(of: "2026-11-07T23:34:50.029Z", with: "2026-11-07T23:00:01.000Z")
            .replacingOccurrences(of: "\"before\": 7", with: "\"before\": null"))
        timeline.apply(older: older)
        #expect(timeline.messages.map(\.id) == ["btm_6", "btm_7", "btm_8", "btm_9"])
        #expect(!timeline.hasOlder)
    }

    @Test func deltaUpdatesAStatusInPlaceAndAppendsNewMessages() throws {
        let page = try decode(BotThreadPage.self, Self.pageJSON)
        var timeline = BotThreadTimeline(threadID: page.threadID)
        timeline.apply(initial: page)
        let delta = try decode(BotThreadPage.self, """
        {"thread_id": "bt_02b7b858fd6d010b5623", "coverage": "own_side", "rev": 5, "participants": [], "messages": [
          {"id": "btm_9", "exchange_id": "out:aa", "sender_key": "relay:xyz", "text": "green",
           "at": "2026-11-07T23:34:50.029Z", "part": "reply", "status": "failed", "status_text": "Remote was offline"},
          {"id": "btm_10", "exchange_id": "out:bb", "sender_key": "local:alpha", "text": "again",
           "at": "2026-11-07T23:40:00.000Z", "part": "message", "status": "pending", "status_text": "Waiting for Remote"}]}
        """)
        timeline.apply(delta: delta)
        #expect(timeline.messages.map(\.id) == ["btm_8", "btm_9", "btm_10"])
        #expect(timeline.messages[1].status == .failed)
        #expect(timeline.messages[1].statusText == "Remote was offline")
        #expect(timeline.revision == 5)
        #expect(timeline.isOwnSideOnly)
        #expect(timeline.participants.count == 2)
    }

    @Test func deltaNeverOpensAGapWhenNewerPagesAreStillUnloaded() throws {
        let page = try decode(BotThreadPage.self, Self.pageJSON.replacingOccurrences(of: "\"after\": null", with: "\"after\": 9"))
        var timeline = BotThreadTimeline(threadID: page.threadID)
        timeline.apply(initial: page)
        let delta = try decode(BotThreadPage.self, """
        {"thread_id": "bt_02b7b858fd6d010b5623", "coverage": "both_sides", "rev": 9, "participants": [], "messages": [
          {"id": "btm_30", "exchange_id": "out:cc", "sender_key": "local:alpha", "text": "far",
           "at": "2026-11-08T10:00:00.000Z", "part": "message", "status": "answered"}]}
        """)
        timeline.apply(delta: delta)
        #expect(timeline.messages.map(\.id) == ["btm_8", "btm_9"])
    }

    @Test func entriesShowTheNameOnARunStartAndTheAvatarOnARunEnd() {
        let base = Date(timeIntervalSince1970: 1_730_000_000)
        func message(_ id: Int, _ sender: String, at offset: TimeInterval) -> BotThreadMessage {
            BotThreadMessage(id: "btm_\(id)", exchangeID: "out:aa", senderKey: sender, text: "m\(id)", at: base.addingTimeInterval(offset))
        }
        var timeline = BotThreadTimeline(threadID: "bt_x")
        let page = BotThreadPage(
            threadID: "bt_x", participants: [], messages: [
                message(1, "a", at: 0), message(2, "a", at: 10), message(3, "b", at: 20), message(4, "b", at: 20 + ChatTimeline.separatorGap),
            ],
            focusIndex: nil, before: nil, after: nil, rev: 4, coverage: "both_sides", historySince: nil
        )
        timeline.apply(initial: page)
        let entries = timeline.entries()
        #expect(entries.map(\.showsName) == [true, false, true, true])
        #expect(entries.map(\.showsAvatar) == [false, true, true, true])
        #expect(entries.map { $0.separator != nil } == [true, false, false, true])
    }
}
