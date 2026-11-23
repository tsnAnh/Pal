import Foundation
@testable import PalChat
import PalProtocol
import Testing

private func metadata(_ code: String) -> JSONValue {
    ["error": "x", "error_surface": ["layer": "auth", "code": .string(code), "retryable": false]]
}

private func failedTurn(id: String = "r:2", kind: String? = "failed_turn", metadata: JSONValue?) -> TimelineEntryWire {
    TimelineEntryWire(id: id, role: .assistant, text: "Not connected.", displayKind: kind, displayMetadata: metadata, rowID: 2)
}

private func isNoProvider(_ item: TranscriptItem) -> Bool { item.content == .noProvider }

private func timeline(_ entries: [TimelineEntryWire]) throws -> Timeline {
    var timeline = Timeline()
    let snapshot: JSONValue = ["session_id": "s1", "messages": [], "replay_epoch": "e1", "last_sequence": 0]
    timeline.adoptLive(try snapshot.decoded(as: SessionSnapshot.self))
    timeline.mergeNewest(TimelinePageWire(entries: entries, older: nil, revision: "r1"))
    return timeline
}

private func complete(_ payload: JSONValue, streamed: String? = nil) throws -> Transcript {
    var transcript = Transcript()
    let snapshot: JSONValue = ["session_id": "s1", "messages": [], "replay_epoch": "e1", "last_sequence": 0]
    _ = transcript.reconcile(with: try snapshot.decoded(as: SessionSnapshot.self))
    var seq = 0
    func send(_ type: String, _ body: JSONValue) {
        seq += 1
        _ = transcript.apply(SessionEventFrame(event: SessionEvent(type: type, payload: body), sessionID: "s1", seq: seq, replayEpoch: "e1"))
    }
    send("message.start", ["turn_id": "t1"])
    if let streamed { send("message.delta", ["text": .string(streamed), "turn_id": "t1", "segment": 0]) }
    send("message.complete", payload)
    return transcript
}

@Suite("No provider card")
struct NoProviderCardTests {
    @Test("a failed-turn row carrying the code projects to the card")
    func storedRowBecomesCard() throws {
        let rows = try timeline([failedTurn(metadata: metadata("no_provider_configured"))]).rows(links: [])
        #expect(rows.map(\.item).filter(isNoProvider).count == 1)
        #expect(rows.count == 1)
    }

    @Test("other codes, a missing code or another row kind stay assistant text")
    func otherRowsStayText() throws {
        for entry in [
            failedTurn(metadata: metadata("auth_permanent")),
            failedTurn(metadata: nil),
            failedTurn(kind: nil, metadata: metadata("no_provider_configured")),
        ] {
            let rows = try timeline([entry]).rows(links: [])
            #expect(rows.count == 1)
            #expect(!isNoProvider(rows[0].item))
        }
    }

    @Test("a live completion carrying the code shows the card, not the CLI text")
    func liveCompletionBecomesCard() throws {
        let payload: JSONValue = ["text": "⚠️ run hermes model", "status": "error", "error_surface": ["code": "no_provider_configured"]]
        let transcript = try complete(payload)
        #expect(transcript.items.map(\.content) == [.noProvider])
        #expect(transcript.assistantTexts.isEmpty)
    }

    @Test("a streamed bubble is replaced by the card")
    func streamedBubbleBecomesCard() throws {
        let payload: JSONValue = ["text": "⚠️ run hermes model", "status": "error", "error_surface": ["code": "no_provider_configured"]]
        let transcript = try complete(payload, streamed: "⚠️ run")
        #expect(transcript.items.map(\.content) == [.noProvider])
    }

    @Test("a live completion with another code or none keeps its text")
    func liveOtherFailureKeepsText() throws {
        let other: JSONValue = ["text": "boom", "status": "error", "error_surface": ["code": "rate_limit"]]
        let plain: JSONValue = ["text": "boom", "status": "error"]
        for payload in [other, plain] {
            #expect(try complete(payload).assistantTexts == ["boom"])
        }
    }

    @Test("the live card settles into the stored card instead of doubling")
    func liveCardMergesWithStoredCard() throws {
        var timeline = try timeline([])
        let payload: JSONValue = ["text": "⚠️ x", "status": "error", "error_surface": ["code": "no_provider_configured"]]
        _ = timeline.apply(SessionEventFrame(event: SessionEvent(type: "message.complete", payload: payload), sessionID: "s1", seq: 1, replayEpoch: "e1"))
        #expect(timeline.rows(links: []).count == 1)
        timeline.mergeNewest(TimelinePageWire(entries: [failedTurn(metadata: metadata("no_provider_configured"))], older: nil, revision: "r2"))
        let rows = timeline.rows(links: [])
        #expect(rows.count == 1)
        #expect(isNoProvider(rows[0].item))
    }
}
