import Foundation
@testable import PalChat
import PalProtocol
import PalTransport
import Synchronization
import Testing

private final class ScriptedSource: HeldDraftSource, Sendable {
    let byProfile: [String: [HeldDraft]]
    let broken: Set<String>
    let answers = Mutex<[String]>([])

    init(_ byProfile: [String: [HeldDraft]], broken: Set<String> = []) {
        self.byProfile = byProfile
        self.broken = broken
    }

    func drafts(profile: String) async throws -> [HeldDraft] {
        if broken.contains(profile) { throw URLError(.cannotConnectToHost) }
        return byProfile[profile] ?? []
    }

    func answer(profile: String, draftID: String, choice: HeldDraftChoice, editedText: String?) async throws -> HeldDraftOutcome {
        answers.withLock { $0.append("\(profile)/\(draftID)/\(choice.rawValue)/\(editedText ?? "-")") }
        return choice == .once ? .sent : .cancelled
    }
}

private func held(_ id: String, to recipient: String = "Sam") -> HeldDraft {
    HeldDraft(id: id, channel: "telegram", recipient: recipient, text: "hello \(recipient)")
}

@Suite("Held drafts list")
@MainActor
struct HeldDraftsModelTests {
    private let ada = HeldDraftBot(name: "ada", displayName: "Ada")
    private let bo = HeldDraftBot(name: "bo", displayName: "Bo")

    @Test func listsEveryWaitingMessageOfEveryBotAndCountsThemPerBot() async {
        let model = HeldDraftsModel(source: ScriptedSource(["ada": [held("a1"), held("a2")], "bo": [held("b1")]]))
        await model.load(bots: [ada, bo])
        #expect(model.entries.map(\.id) == ["ada/a1", "ada/a2", "bo/b1"])
        #expect(model.count(for: "ada") == 2)
        #expect(model.count(for: "bo") == 1)
        #expect(model.count(for: nil) == 3)
        #expect(model.entries(for: "bo").map(\.draft.id) == ["b1"])
        #expect(model.phase == .ready)
    }

    @Test func aBotThatCannotBeReachedIsNamedAndTheOthersStillShow() async {
        let model = HeldDraftsModel(source: ScriptedSource(["ada": [held("a1")], "bo": [held("b1")]], broken: ["bo"]))
        await model.load(bots: [ada, bo])
        #expect(model.entries.map(\.id) == ["ada/a1"])
        #expect(model.unreachable == [bo])
    }

    @Test func reloadingOneBotReplacesOnlyItsEntries() async {
        let model = HeldDraftsModel(source: ScriptedSource(["ada": [held("a1")], "bo": [held("b1")]]))
        await model.load(bots: [ada, bo])
        await model.load(bots: [ada])
        #expect(model.entries.map(\.id).sorted() == ["ada/a1", "bo/b1"])
    }

    @Test func theSheetAnswersWithThisBotsProfileThisDraftIdAndTheExactText() async throws {
        let source = ScriptedSource(["ada": [held("a1")]])
        let model = HeldDraftsModel(source: source)
        await model.load(bots: [ada])
        let sheet = model.sheet(for: try #require(model.entries.first))
        sheet.beginEdit()
        sheet.editText = "hello Sam, at 6"
        await sheet.sendEdited()
        #expect(source.answers.withLock { $0 } == ["ada/a1/once/hello Sam, at 6"])
    }

    @Test func cancelAndBackThroughTheListSendNothing() async throws {
        let source = ScriptedSource(["ada": [held("a1")]])
        let model = HeldDraftsModel(source: source)
        await model.load(bots: [ada])
        let sheet = model.sheet(for: try #require(model.entries.first))
        sheet.beginEdit()
        sheet.back()
        #expect(source.answers.withLock { $0 }.isEmpty)
        await sheet.cancel()
        #expect(source.answers.withLock { $0 } == ["ada/a1/deny/-"])
    }

    @Test func statusLineSaysWaitingAndExpiry() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let waiting = HeldDraftEntry(bot: HeldDraftBot(name: "ada", displayName: "Ada"), draft: held("a1"))
        #expect(waiting.statusLine(now: now) == "Waiting")
        let expiring = HeldDraftEntry(
            bot: HeldDraftBot(name: "ada", displayName: "Ada"),
            draft: HeldDraft(id: "a2", channel: "telegram", recipient: "Sam", text: "x", expiresAt: now.addingTimeInterval(3600))
        )
        #expect(expiring.statusLine(now: now).hasPrefix("Waiting, expires "))
        let expired = HeldDraftEntry(
            bot: HeldDraftBot(name: "ada", displayName: "Ada"),
            draft: HeldDraft(id: "a3", channel: "telegram", recipient: "Sam", text: "x", standing: .expired)
        )
        #expect(expired.statusLine(now: now) == "Expired")
    }
}

@Suite("Held draft cards")
struct HeldDraftCardTests {
    private func card(
        _ draft: [String: JSONValue],
        id: String = "draft:0123456789abcdef0123456789abcdef",
        choices: [JSONValue] = ["once", "deny"]
    ) -> JSONValue {
        ["request_id": .string(id), "command": "Running late.", "choices": .array(choices), "draft": .object(draft)]
    }

    private let outbound: [String: JSONValue] = [
        "kind": "outbound_message", "channel": "telegram", "recipient": "Sam", "text": "Running late.",
        "state": "pending", "editable": true, "expires_at": 1_700_003_600.0,
    ]

    @Test func parsesTheGatewayCard() throws {
        let parsed = try #require(HeldDraft(card: card(outbound)))
        #expect(parsed.id == "0123456789abcdef0123456789abcdef")
        #expect(parsed.promptID == "draft:0123456789abcdef0123456789abcdef")
        #expect(parsed.text == "Running late.")
        #expect(parsed.channelName == "Telegram")
        #expect(parsed.headerLine == "Message to Sam on Telegram (waiting)")
        #expect(parsed.standing == .waiting)
        #expect(parsed.canSend && parsed.canEdit)
        #expect(parsed.expiresAt == Date(timeIntervalSince1970: 1_700_003_600))
    }

    @Test func aCancelOnlyCardCannotBeSentOrEdited() throws {
        let parsed = try #require(HeldDraft(card: card(outbound, choices: ["deny"])))
        #expect(!parsed.canSend && !parsed.canEdit)
    }

    @Test func aFailedCardCarriesItsRealReason() throws {
        var failed = outbound
        failed["state"] = "failed"
        failed["error"] = "Telegram said: chat not found."
        let parsed = try #require(HeldDraft(card: card(failed)))
        #expect(parsed.standing == .failed(reason: "Telegram said: chat not found"))
    }

    @Test func anExpiredCardCannotBeSent() throws {
        var expired = outbound
        expired["state"] = "expired"
        let parsed = try #require(HeldDraft(card: card(expired)))
        #expect(parsed.standing == .expired)
        #expect(!parsed.canSend)
    }

    @Test func nonDraftApprovalsAreNotDrafts() {
        #expect(HeldDraft(card: card(outbound, id: "approval-1")) == nil)
        #expect(HeldDraft(card: card(outbound, id: "draft:")) == nil)
        #expect(HeldDraft(card: card(["kind": "other", "text": "x"])) == nil)
        #expect(HeldDraft(card: ["request_id": "draft:abc", "command": "rm -rf build", "choices": ["once"]]) == nil)
    }
}
