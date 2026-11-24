import Foundation
@testable import PalChat
import PalProtocol
import PalTransport
import Synchronization
import Testing

private final class AnswerLog: Sendable {
    struct Call: Equatable {
        var draftID: String
        var choice: HeldDraftChoice
        var editedText: String?
    }

    private let stored = Mutex<[Call]>([])
    var calls: [Call] { stored.withLock { $0 } }

    func record(_ draft: HeldDraft, _ choice: HeldDraftChoice, _ text: String?) {
        stored.withLock { $0.append(Call(draftID: draft.id, choice: choice, editedText: text)) }
    }
}

private final class Counter: Sendable {
    private let stored = Mutex(0)

    func next() -> Int {
        stored.withLock { count -> Int in
            count += 1
            return count
        }
    }
}

private struct RefusalCase {
    let reason: String
    let state: String?
    let message: String
    let expect: HeldDraftSheetModel.Phase

    init(_ reason: String, _ state: String?, _ message: String, _ expect: HeldDraftSheetModel.Phase) {
        self.reason = reason
        self.state = state
        self.message = message
        self.expect = expect
    }
}

private func failedMessage(_ reason: String) -> String {
    "The message was NOT sent: \(reason). It is still waiting for approval; approve it again to retry."
}

private func refusal(_ reason: String, state: String?, message: String = "refused") -> any Error {
    var data: [String: JSONValue] = ["reason": .string(reason)]
    if let state { data["state"] = .string(state) }
    return GatewayTransportError.rpc(RPCError(code: 4134, message: message, data: .object(data)))
}

private let fakeID = "0123456789abcdef0123456789abcdef"
private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

private func draft(
    text: String = "Running late, start without me.",
    standing: HeldDraft.Standing = .waiting,
    canSend: Bool = true
) -> HeldDraft {
    HeldDraft(id: fakeID, channel: "telegram", recipient: "Sam", text: text, standing: standing, canSend: canSend, canEdit: true)
}

@MainActor
private func model(
    _ log: AnswerLog,
    draft held: HeldDraft = draft(),
    reply: @escaping @Sendable (HeldDraftChoice, String?) async throws -> HeldDraftOutcome = { choice, _ in
        choice == .once ? .sent : .cancelled
    }
) -> HeldDraftSheetModel {
    HeldDraftSheetModel(
        draft: held,
        now: { fixedNow },
        answer: { draft, choice, text in
            log.record(draft, choice, text)
            return try await reply(choice, text)
        }
    )
}

@Suite("Held draft sheet")
@MainActor
struct HeldDraftSheetTests {
    @Test func sendAuthorizesExactlyThisDraftAndItsShownText() async {
        let log = AnswerLog()
        let sheet = model(log)
        await sheet.send()
        #expect(log.calls == [.init(draftID: fakeID, choice: .once, editedText: nil)])
        #expect(sheet.phase == .sent(at: fixedNow))
        #expect(sheet.detailLine == "Telegram confirmed it. It cannot be sent again.")
        #expect(sheet.statusLine?.hasPrefix("Sent once, ") == true)
    }

    @Test func cancelDeniesAndNeverSends() async {
        let log = AnswerLog()
        let sheet = model(log)
        await sheet.cancel()
        #expect(log.calls == [.init(draftID: fakeID, choice: .deny, editedText: nil)])
        #expect(sheet.phase == .cancelled)
        #expect(sheet.statusLine == "Not sent. Cancelled.")
    }

    @Test func editThenBackSendsNothingAndKeepsTheOriginalText() async {
        let log = AnswerLog()
        let sheet = model(log)
        sheet.beginEdit()
        #expect(sheet.phase == .editing)
        #expect(sheet.editText == "Running late, start without me.")
        sheet.editText = "Something else entirely"
        sheet.back()
        #expect(sheet.phase == .waiting)
        #expect(sheet.shownText == "Running late, start without me.")
        #expect(log.calls.isEmpty)
        sheet.beginEdit()
        #expect(sheet.editText == "Running late, start without me.")
    }

    @Test func sendEditedCarriesTheExactEditedText() async {
        let log = AnswerLog()
        let sheet = model(log)
        sheet.beginEdit()
        sheet.editText = "  Running late, start at 6.  "
        await sheet.sendEdited()
        #expect(log.calls == [.init(draftID: fakeID, choice: .once, editedText: "Running late, start at 6.")])
        #expect(sheet.shownText == "Running late, start at 6.")
        #expect(sheet.phase == .sent(at: fixedNow))
    }

    @Test func sendEditedWithoutAChangeSendsNoEditedText() async {
        let log = AnswerLog()
        let sheet = model(log)
        sheet.beginEdit()
        await sheet.sendEdited()
        #expect(log.calls == [.init(draftID: fakeID, choice: .once, editedText: nil)])
    }

    @Test func anEmptyEditCannotBeSent() async {
        let log = AnswerLog()
        let sheet = model(log)
        sheet.beginEdit()
        sheet.editText = "   \n"
        #expect(!sheet.canSendEdited)
        await sheet.sendEdited()
        #expect(log.calls.isEmpty)
        #expect(sheet.phase == .editing)
    }

    @Test func aSecondPressWhileSendingNeverAsksTwice() async {
        let log = AnswerLog()
        let sheet = model(log) { _, _ in
            try await Task.sleep(for: .milliseconds(80))
            return .sent
        }
        async let first: Void = sheet.send()
        async let second: Void = sheet.send()
        async let third: Void = sheet.cancel()
        _ = await (first, second, third)
        #expect(log.calls.count == 1)
        #expect(sheet.phase == .sent(at: fixedNow))
    }

    @Test func aSentDraftCannotBeAnsweredAgain() async {
        let log = AnswerLog()
        let sheet = model(log)
        await sheet.send()
        await sheet.send()
        await sheet.cancel()
        sheet.beginEdit()
        #expect(log.calls.count == 1)
        #expect(sheet.phase == .sent(at: fixedNow))
    }

    @Test func aCancelledDraftCannotBeSent() async {
        let log = AnswerLog()
        let sheet = model(log)
        await sheet.cancel()
        await sheet.send()
        #expect(log.calls.map(\.choice) == [.deny])
    }

    @Test func controlsAreOffWhileSending() async {
        let sheet = model(AnswerLog()) { _, _ in
            try await Task.sleep(for: .milliseconds(80))
            return .sent
        }
        let sending = Task { await sheet.send() }
        try? await Task.sleep(for: .milliseconds(20))
        #expect(sheet.phase == .sending)
        #expect(sheet.statusLine == "Sending…")
        #expect(!sheet.canChoose && !sheet.canSend && !sheet.canEdit)
        await sending.value
    }

    @Test func anExpiredDraftOffersOnlyDiscard() async {
        let log = AnswerLog()
        let sheet = model(log, draft: draft(standing: .expired, canSend: false))
        #expect(sheet.phase == .expired)
        #expect(sheet.statusLine == "This draft waited too long. Ask the bot to write it again.")
        #expect(!sheet.canSend && !sheet.canEdit && !sheet.canChoose && sheet.canDiscard)
        await sheet.send()
        #expect(log.calls.isEmpty)
        await sheet.cancel()
        #expect(log.calls == [.init(draftID: fakeID, choice: .deny, editedText: nil)])
        #expect(sheet.phase == .cancelled)
    }

    @Test func aDraftThatCanOnlyBeCancelledCannotBeSent() async {
        let log = AnswerLog()
        let sheet = model(log, draft: draft(canSend: false))
        #expect(!sheet.canSend && !sheet.canEdit && sheet.canChoose)
        await sheet.send()
        #expect(log.calls.isEmpty)
    }

    @Test func eachRefusalOnSendLandsOnTheTrueState() async {
        let cases: [RefusalCase] = [
            RefusalCase("already_sent", "sent", "This draft was already sent.", .sent(at: nil)),
            RefusalCase("already_cancelled", "cancelled", "This draft was cancelled and was not sent.", .cancelled),
            RefusalCase("discarded", "cancelled", "This draft was cancelled and was not sent.", .cancelled),
            RefusalCase("expired", "expired", "This draft expired and can no longer be sent.", .expired),
            RefusalCase("in_progress", "approved", "Being sent right now.", .unavailable("Being sent right now.")),
            RefusalCase("busy", "pending", "Answered somewhere else.", .unavailable("Answered somewhere else.")),
            RefusalCase("not_found", nil, "This draft no longer exists.", .unavailable("This draft no longer exists.")),
            RefusalCase("corrupt", nil, "This draft could not be read.", .unavailable("This draft could not be read.")),
            RefusalCase("send_failed", "failed", failedMessage("rate limited"), .failed(reason: "rate limited")),
            RefusalCase("send_failed", "failed", "something unexpected", .failed(reason: nil)),
        ]
        for item in cases {
            let sheet = model(AnswerLog()) { _, _ in throw refusal(item.reason, state: item.state, message: item.message) }
            await sheet.send()
            #expect(sheet.phase == item.expect, "\(item.reason)")
        }
    }

    @Test func aRefusedEditReturnsToTheEditorWithTheReasonAndSendsNothingElse() async {
        let log = AnswerLog()
        let sheet = model(log) { _, _ in throw refusal("invalid_edit", state: "pending", message: "That text is too long.") }
        sheet.beginEdit()
        sheet.editText = "x"
        await sheet.sendEdited()
        #expect(sheet.phase == .editing)
        #expect(sheet.editText == "x")
        #expect(sheet.problem == "That text is too long.")
        #expect(sheet.shownText == "Running late, start without me.")
        #expect(log.calls.count == 1)
    }

    @Test func anUnviewableDraftTurnsSendOffForGood() async {
        let sheet = model(AnswerLog()) { _, _ in throw refusal("unviewable", state: "pending", message: "Only cancel is possible.") }
        await sheet.send()
        #expect(sheet.phase == .waiting)
        #expect(sheet.blocksSend && !sheet.canSend)
        #expect(sheet.problem != nil)
    }

    @Test func aFailedSendNamesTheChannelAndTheRealReason() async {
        let sheet = model(AnswerLog()) { _, _ in
            throw refusal("send_failed", state: "failed", message: failedMessage("rate limited"))
        }
        await sheet.send()
        #expect(sheet.statusLine == "Not sent. Telegram said: rate limited. It may or may not have gone out; check Telegram before sending again.")
        #expect(sheet.canSend && sheet.canChoose)
    }

    @Test func aTransportFailureOnSendIsShownAsMayOrMayNotHaveGoneOut() async {
        let sheet = model(AnswerLog()) { _, _ in throw URLError(.networkConnectionLost) }
        await sheet.send()
        #expect(sheet.phase == .failed(reason: nil))
        #expect(sheet.statusLine == "Not sent. It may or may not have gone out, check before sending again.")
    }

    @Test func sendAgainAfterAFailureAsksOnceMoreAndTheServerStaysTheJudge() async {
        let log = AnswerLog()
        let attempts = Counter()
        let sheet = model(log) { _, _ in
            let number = attempts.next()
            throw number == 1 ? URLError(.timedOut) as any Error : refusal("already_sent", state: "sent")
        }
        await sheet.send()
        #expect(sheet.phase == .failed(reason: nil))
        await sheet.send()
        #expect(log.calls.count == 2)
        #expect(sheet.phase == .sent(at: nil))
        await sheet.send()
        #expect(log.calls.count == 2)
    }

    @Test func sendAgainAfterAFailedEditResendsTheSameEditedText() async {
        let log = AnswerLog()
        let attempts = Counter()
        let sheet = model(log) { _, _ in
            let number = attempts.next()
            if number == 1 { throw refusal("send_failed", state: "failed", message: failedMessage("offline")) }
            return .sent
        }
        sheet.beginEdit()
        sheet.editText = "At 6 then."
        await sheet.sendEdited()
        #expect(sheet.shownText == "At 6 then.")
        #expect(sheet.canEdit == false)
        await sheet.send()
        #expect(log.calls.map(\.editedText) == ["At 6 then.", "At 6 then."])
        #expect(sheet.phase == .sent(at: fixedNow))
    }

    @Test func notReachingTheBotMeansNothingWasSentAndTheCardComesBack() async {
        let sheet = model(AnswerLog()) { _, _ in throw HeldDraftDeskError.unreachable }
        await sheet.send()
        #expect(sheet.phase == .waiting)
        #expect(sheet.problem == "Couldn't reach your bot. Nothing was sent. Try again.")
        #expect(sheet.canSend)
    }

    @Test func aCancelThatCouldNotBeDeliveredReturnsToThePreviousCard() async {
        let sheet = model(AnswerLog()) { _, _ in throw URLError(.notConnectedToInternet) }
        await sheet.cancel()
        #expect(sheet.phase == .waiting)
        #expect(sheet.problem != nil)
    }

    @Test func aCancelThatLostTheRaceToASendShowsItWasSent() async {
        let sheet = model(AnswerLog()) { _, _ in throw refusal("already_sent", state: "sent") }
        await sheet.cancel()
        #expect(sheet.phase == .sent(at: nil))
        #expect(sheet.statusLine == "Sent once")
    }

    @Test func aFailedDraftFromTheListOffersSendAgainAndCancel() async {
        let log = AnswerLog()
        let sheet = model(log, draft: draft(standing: .failed(reason: "offline")))
        #expect(sheet.phase == .failed(reason: "offline"))
        #expect(sheet.statusLine == "Not sent. Telegram said: offline. It may or may not have gone out; check Telegram before sending again.")
        await sheet.cancel()
        #expect(log.calls.map(\.choice) == [.deny])
    }
}
