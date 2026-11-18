import Foundation
import PalChat
import PalProtocol
import Testing

@Suite("Routine output rows")
struct RoutineOutputTests {
    private func wrap(_ job: String, _ body: String) -> String {
        "[Cronjob \"\(job)\" output — scheduled job, not the user. Review it, act on anything that needs action, and summarize for the chat.]\n\n\(body)"
    }

    private func kind(_ text: String, kind: String? = nil, metadata: JSONValue? = nil) -> InboundKind {
        let row = TimelineEntryWire(id: "u1", role: .user, text: text, displayKind: kind, displayMetadata: metadata)
        return InboundKind.classify(text: text, of: row)
    }

    @Test func gatewayKindWithJobNameAndBodyIsRoutineOutput() {
        let metadata: JSONValue = ["job_name": "faker-kit-babysit", "status": "ok"]
        #expect(kind("#201 merged.\n\nNo pull request is open.", kind: "routine_output", metadata: metadata)
            == .routineOutput(jobName: "faker-kit-babysit", body: "#201 merged.\n\nNo pull request is open.", failed: false))
    }

    @Test func gatewayJobNameBeatsTheParsedOne() {
        let text = wrap("parsed", "body")
        #expect(kind(text, kind: "routine_output", metadata: ["job_name": "sent"]) == .routineOutput(jobName: "sent", body: "body", failed: false))
    }

    @Test func failedStatusMarksTheRunFailed() {
        let text = "The run did not finish."
        let expected = InboundKind.routineOutput(jobName: "j", body: text, failed: true)
        for metadata: JSONValue in [["job_name": "j", "status": "failed"], ["job_name": "j", "ok": false], ["job_name": "j", "failed": true]] {
            #expect(kind(text, kind: "routine_output", metadata: metadata) == expected)
        }
    }

    @Test func wrappedTextIsClassifiedWithoutAnyKindOrWithTheGenericOne() {
        let text = wrap("morning-digest", "**Today**\n\n- 3 pull requests")
        let expected = InboundKind.routineOutput(jobName: "morning-digest", body: "**Today**\n\n- 3 pull requests", failed: false)
        #expect(kind(text) == expected)
        #expect(kind(text, kind: "internal_notification") == expected)
    }

    @Test func jobNamesKeepQuotesAndUnicode() {
        #expect(kind(wrap("Báo cáo \"sáng\" 🌅", "xong")) == .routineOutput(jobName: "Báo cáo \"sáng\" 🌅", body: "xong", failed: false))
    }

    @Test func wrapperLineNeverReachesTheBody() {
        guard case .routineOutput(_, let body, _) = kind(wrap("j", "line one\n\nline two")) else {
            Issue.record("not routine output")
            return
        }
        #expect(body == "line one\n\nline two")
        #expect(!body.contains("scheduled job, not the user"))
    }

    @Test func thirtyThousandCharactersStayWhole() {
        let long = String(repeating: "abcdefghi ", count: 3000)
        guard case .routineOutput(_, let body, _) = kind(wrap("big", long)) else {
            Issue.record("not routine output")
            return
        }
        #expect(body.count == long.trimmingCharacters(in: .whitespacesAndNewlines).count)
        #expect(body.count >= 29_000)
    }

    @Test func noticesWithoutABodyAreInternal() {
        #expect(kind("tick", kind: "internal_notification") == .internalNotice)
        #expect(kind("", kind: "routine_output", metadata: ["job_name": "j"]) == .internalNotice)
        #expect(kind(wrap("j", ""), kind: "internal_notification") == .internalNotice)
    }

    @Test func peopleAreUnchanged() {
        #expect(kind("hello there") == .person)
        #expect(kind("my [Cronjob \"x\" output — y] note\n\nz") == .person)
        #expect(kind(wrap("j", "body"), kind: "steer") == .person)
    }

    @Test func firstSentenceStopsAtTheFirstTerminatorFollowedBySpace() {
        let split = InboundKind.splitFirstSentence(of: "The run did not finish: HTTP v1.2 returned 403. It will retry.\n\nNext at 10:30.")
        #expect(split.lead == "The run did not finish: HTTP v1.2 returned 403.")
        #expect(split.rest == "It will retry.\n\nNext at 10:30.")
    }

    @Test func firstSentenceFallsBackToTheFirstLine() {
        let split = InboundKind.splitFirstSentence(of: "Timed out\nsecond line")
        #expect(split.lead == "Timed out")
        #expect(split.rest == "second line")
        #expect(InboundKind.splitFirstSentence(of: "Only one.") == (lead: "Only one.", rest: ""))
    }

    @Test func snapshotRowsCarryTheRoutineKind() throws {
        let object: JSONValue = [
            "session_id": "s1", "running": false, "replay_epoch": "e1", "last_sequence": 0, "execution_generation": 1,
            "pending": [], "prompts": [],
            "messages": [["role": "user", "text": .string(wrap("nightly", "all good")), "row_id": 1, "display_kind": "internal_notification"]],
        ]
        var transcript = Transcript()
        transcript.load(try object.decoded(as: SessionSnapshot.self))
        #expect(transcript.items.first?.inbound == .routineOutput(jobName: "nightly", body: "all good", failed: false))
    }
}
