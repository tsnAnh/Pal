import Foundation
@testable import PalChat
import PalProtocol
import PalTransport
import Testing

private let fakeID = "0123456789abcdef0123456789abcdef"

private let cardWire: JSONValue = [
    "approvals": [[
        "request_id": .string("draft:\(fakeID)"), "command": "Running late.", "choices": ["once", "deny"],
        "draft": ["kind": "outbound_message", "channel": "telegram", "recipient": "Sam", "text": "Running late.", "state": "pending", "editable": true],
    ], [
        "request_id": "legacy-1", "command": "rm -rf build", "description": "recursive delete", "choices": ["once", "deny"],
    ]],
]

private struct Rig {
    let script: BotScript
    let gateway: FakeGateway
    let desk: HeldDraftDesk
}

@Suite("Held draft desk", .serialized)
struct HeldDraftDeskTests {
    private func start(_ configure: (BotScript) -> Void = { _ in }) async throws -> Rig {
        let script = BotScript()
        script.override("approval.pending") { _ in .result(cardWire) }
        configure(script)
        let gateway = try await FakeGateway.start(script.handle)
        return Rig(script: script, gateway: gateway, desk: HeldDraftDesk(connector: ScriptedConnector(url: gateway.url)))
    }

    @Test func listsOnlyTheHeldDraftsOfTheBotsChat() async throws {
        let rig = try await start()
        let drafts = try await rig.desk.drafts(profile: "bot")
        #expect(drafts.map(\.id) == [fakeID])
        let asked = try #require(rig.script.calls("approval.pending").first)
        #expect(asked["session_id"]?.stringValue == BotScript.sessionID)
        rig.gateway.stop()
    }

    @Test func sendCarriesTheExactPromptIdAndTheExactEditedText() async throws {
        let rig = try await start { $0.override("approval.respond") { _ in .result(["status": "resolved", "state": "sent"]) } }
        let outcome = try await rig.desk.answer(profile: "bot", draftID: fakeID, choice: .once, editedText: "Running late, at 6.")
        #expect(outcome == .sent)
        let sent = rig.script.calls("approval.respond")
        #expect(sent.count == 1)
        #expect(sent[0]["prompt_id"]?.stringValue == "draft:\(fakeID)")
        #expect(sent[0]["choice"]?.stringValue == "once")
        #expect(sent[0]["edited_text"]?.stringValue == "Running late, at 6.")
        rig.gateway.stop()
    }

    @Test func sendWithoutAnEditCarriesNoEditedText() async throws {
        let rig = try await start { $0.override("approval.respond") { _ in .result(["status": "resolved", "state": "sent"]) } }
        _ = try await rig.desk.answer(profile: "bot", draftID: fakeID, choice: .once, editedText: nil)
        #expect(rig.script.calls("approval.respond")[0]["edited_text"] == nil)
        rig.gateway.stop()
    }

    @Test func cancelIsADenyThatNeverCarriesText() async throws {
        let rig = try await start { $0.override("approval.respond") { _ in .result(["status": "resolved", "state": "cancelled"]) } }
        let outcome = try await rig.desk.answer(profile: "bot", draftID: fakeID, choice: .deny, editedText: "ignored")
        #expect(outcome == .cancelled)
        let sent = rig.script.calls("approval.respond")
        #expect(sent[0]["choice"]?.stringValue == "deny")
        #expect(sent[0]["edited_text"] == nil)
        rig.gateway.stop()
    }

    @Test func aRefusalSurfacesTheReasonAndStateForTheSheet() async throws {
        let rig = try await start {
            $0.override("approval.respond") { _ in
                .failure(RPCError(code: 4134, message: "This draft was already sent.", data: ["reason": "already_sent", "state": "sent"]))
            }
        }
        do {
            _ = try await rig.desk.answer(profile: "bot", draftID: fakeID, choice: .once, editedText: nil)
            Issue.record("expected a refusal")
        } catch {
            let refusal = try #require(HeldDraftRefusal(error))
            #expect(refusal.reason == "already_sent" && refusal.state == "sent")
        }
        rig.gateway.stop()
    }

    @Test func aStateThatContradictsTheChoiceIsNeverTakenAsSent() async throws {
        let rig = try await start { $0.override("approval.respond") { _ in .result(["status": "resolved", "state": "cancelled"]) } }
        await #expect(throws: ChatError.self) {
            _ = try await rig.desk.answer(profile: "bot", draftID: fakeID, choice: .once, editedText: nil)
        }
        rig.gateway.stop()
    }

    @Test func noBotChatMeansNoDraftsAndNothingToAnswer() async throws {
        let rig = try await start { $0.override("session.list") { _ in .result(["sessions": []]) } }
        #expect(try await rig.desk.drafts(profile: "bot").isEmpty)
        await #expect(throws: HeldDraftDeskError.self) {
            _ = try await rig.desk.answer(profile: "bot", draftID: fakeID, choice: .once, editedText: nil)
        }
        #expect(rig.script.calls("approval.respond").isEmpty)
        rig.gateway.stop()
    }
}
