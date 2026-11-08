import Foundation
import HermesChat
import HermesProtocol
import Testing

@Suite("Inbound row classification")
struct InboundKindTests {
    private func transcript(_ rows: [JSONValue], pending: [JSONValue] = []) throws -> Transcript {
        let object: JSONValue = [
            "session_id": "s1",
            "messages": .array(rows),
            "running": false,
            "replay_epoch": "e1",
            "last_sequence": 0,
            "execution_generation": 1,
            "pending": .array(pending),
            "prompts": [],
        ]
        var transcript = Transcript()
        transcript.load(try object.decoded(as: SessionSnapshot.self))
        return transcript
    }

    private func userRow(_ text: String, kind: String? = nil, timestamp: Double? = nil, id: Int = 1) -> JSONValue {
        var row: [String: JSONValue] = ["role": "user", "text": .string(text), "row_id": .int(id)]
        if let kind { row["display_kind"] = .string(kind) }
        if let timestamp { row["timestamp"] = .double(timestamp) }
        return .object(row)
    }

    private func firstInbound(_ transcript: Transcript) -> InboundKind? {
        transcript.items.first.map(\.inbound)
    }

    @Test func plainUserTextIsAPerson() throws {
        #expect(firstInbound(try transcript([userRow("hello there")])) == .person)
    }

    @Test func botStampParsesSenderHandleAndBody() throws {
        let kind = firstInbound(try transcript([userRow("Message from 🤖 chó UA (@cho-ua): Brief mới đây")]))
        #expect(kind == .botMessage(BotSender(name: "chó UA", handle: "cho-ua"), body: "Brief mới đây"))
    }

    @Test func botStampKeepsMultilineBodyAndToleratesLeadingWhitespace() throws {
        let kind = firstInbound(try transcript([userRow("\n  Message from 🤖 Upwork Hunter (@upwork-hunter): line one\nline two")]))
        #expect(kind == .botMessage(BotSender(name: "Upwork Hunter", handle: "upwork-hunter"), body: "line one\nline two"))
    }

    @Test func nameContainingParenthesesStillSplitsOnTheHandle() throws {
        let kind = firstInbound(try transcript([userRow("Message from 🤖 Rex (the 2nd) (@rex-2): ping")]))
        #expect(kind == .botMessage(BotSender(name: "Rex (the 2nd)", handle: "rex-2"), body: "ping"))
    }

    @Test func stampWithoutHandleTypedByAHumanStaysAPerson() throws {
        #expect(firstInbound(try transcript([userRow("Message from 🤖 Name: hi")])) == .person)
    }

    @Test func internalNotificationWithStampIsABotMessage() throws {
        let kind = firstInbound(try transcript([userRow("Message from 🤖 A (@a): hi", kind: "internal_notification")]))
        #expect(kind == .botMessage(BotSender(name: "A", handle: "a"), body: "hi"))
    }

    @Test func internalNotificationWithoutStampIsASystemNotification() throws {
        #expect(firstInbound(try transcript([userRow("tick", kind: "internal_notification")])) == .systemNotification)
    }

    @Test func processCompletionKindsAreRecognised() throws {
        #expect(firstInbound(try transcript([userRow("done", kind: "process_complete")])) == .processCompletion)
        #expect(firstInbound(try transcript([userRow("done", kind: "async_delegation_complete")])) == .processCompletion)
    }

    @Test func backgroundProcessTextBeatsInternalNotificationKind() throws {
        let text = "[IMPORTANT: Background process proc_1 matched watch pattern \"x\".]\n\n[INTERNAL NOTIFICATION]"
        #expect(firstInbound(try transcript([userRow(text, kind: "internal_notification")])) == .processCompletion)
        #expect(firstInbound(try transcript([userRow(text)])) == .processCompletion)
    }

    @Test func hiddenRowsAreStillDropped() throws {
        #expect(try transcript([userRow("secret", kind: "hidden")]).items.isEmpty)
    }

    @Test func serverTimestampBecomesTheItemDate() throws {
        let stamped = try transcript([userRow("a", timestamp: 1_700_000_000.5)])
        #expect(stamped.items.first?.timestamp == Date(timeIntervalSince1970: 1_700_000_000.5))
        #expect(try transcript([userRow("a")]).items.first?.timestamp == nil)
    }

    @Test func assistantAndToolRowsCarryServerTimestamps() throws {
        let rows: [JSONValue] = [
            .object(["role": "assistant", "text": "hi", "row_id": 2, "timestamp": 1_700_000_100]),
            .object(["role": "tool", "name": "terminal", "tool_call_id": "t1", "row_id": 3, "timestamp": 1_700_000_050]),
        ]
        let items = try transcript(rows).items
        #expect(items.map(\.timestamp) == [Date(timeIntervalSince1970: 1_700_000_100), Date(timeIntervalSince1970: 1_700_000_050)])
    }

    @Test func echoedLocalSendsAreAlwaysPeopleWithoutAServerDate() throws {
        var transcript = Transcript()
        transcript.echoUser(submissionID: "s", text: "Message from 🤖 A (@a): hi")
        #expect(transcript.items.first?.inbound == .person)
        #expect(transcript.items.first?.timestamp == nil)
    }

    @Test func pendingAdmissionWithBotStampIsClassifiedByText() throws {
        let pending: JSONValue = ["admission_id": "a1", "status": "queued", "input_id": "i1", "text": "Message from 🤖 B (@b): yo"]
        let kind = firstInbound(try transcript([], pending: [pending]))
        #expect(kind == .botMessage(BotSender(name: "B", handle: "b"), body: "yo"))
    }

    @Test func displayMetadataIsDecodedAndKept() throws {
        let row: JSONValue = [
            "role": "user", "text": "x", "row_id": 1, "display_kind": "internal_notification",
            "display_metadata": ["reply_expected": true],
        ]
        let message = try row.decoded(as: WireMessage.self)
        #expect(message.displayMetadata?["reply_expected"]?.boolValue == true)
    }
}
