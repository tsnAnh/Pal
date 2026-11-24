import Foundation
import Observation

@MainActor
@Observable
public final class HeldDraftSheetModel {
    public enum Phase: Sendable, Equatable {
        case waiting
        case editing
        case sending
        case sent(at: Date?)
        case failed(reason: String?)
        case cancelled
        case expired
        case unavailable(String)
    }

    public typealias Answer = @Sendable (_ draft: HeldDraft, _ choice: HeldDraftChoice, _ editedText: String?) async throws -> HeldDraftOutcome

    public let draft: HeldDraft
    public private(set) var phase: Phase
    public private(set) var shownText: String
    public private(set) var problem: String?
    public private(set) var blocksSend: Bool
    public private(set) var inFlight: HeldDraftChoice?
    public var editText: String

    private let answer: Answer
    private let now: @Sendable () -> Date

    public init(draft: HeldDraft, now: @escaping @Sendable () -> Date = { Date() }, answer: @escaping Answer) {
        self.draft = draft
        self.answer = answer
        self.now = now
        shownText = draft.text
        editText = draft.text
        blocksSend = !draft.canSend
        switch draft.standing {
        case .waiting: phase = .waiting
        case .failed(let reason): phase = .failed(reason: reason)
        case .expired: phase = .expired
        }
    }

    public var canChoose: Bool {
        switch phase {
        case .waiting, .failed: inFlight == nil
        default: false
        }
    }

    public var canSend: Bool { canChoose && !blocksSend }
    public var canDiscard: Bool { phase == .expired && inFlight == nil }
    public var canEdit: Bool { phase == .waiting && inFlight == nil && draft.canEdit && !blocksSend }
    public var canSendEdited: Bool {
        phase == .editing && inFlight == nil && !blocksSend && !Self.trimmed(editText).isEmpty
    }

    public var headerLine: String {
        switch phase {
        case .waiting, .editing, .sending, .failed: draft.header(waiting: true)
        case .sent, .cancelled, .expired, .unavailable: draft.header(waiting: false)
        }
    }

    public var isSettled: Bool {
        switch phase {
        case .sent, .cancelled, .expired, .unavailable: true
        default: false
        }
    }

    public func beginEdit() {
        guard canEdit else { return }
        editText = shownText
        problem = nil
        phase = .editing
    }

    public func back() {
        guard phase == .editing, inFlight == nil else { return }
        problem = nil
        phase = .waiting
    }

    public func send() async {
        guard canSend else { return }
        await submit(.once, text: shownText, from: phase)
    }

    public func sendEdited() async {
        guard canSendEdited else { return }
        await submit(.once, text: editText, from: .editing)
    }

    public func cancel() async {
        guard canChoose || canDiscard else { return }
        await submit(.deny, text: shownText, from: phase)
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submit(_ choice: HeldDraftChoice, text: String, from previous: Phase) async {
        guard inFlight == nil else { return }
        let edited = choice == .once && Self.trimmed(text) != Self.trimmed(draft.text) ? Self.trimmed(text) : nil
        let attempted = choice == .once ? (edited ?? draft.text) : shownText
        inFlight = choice
        problem = nil
        phase = .sending
        defer { inFlight = nil }
        do {
            let outcome = try await answer(draft, choice, edited)
            shownText = attempted
            switch outcome {
            case .sent: phase = .sent(at: now())
            case .cancelled: phase = .cancelled
            }
        } catch let refusal as HeldDraftRefusal {
            settle(refusal, choice: choice, attempted: attempted, edit: text, previous: previous)
        } catch HeldDraftDeskError.unreachable {
            phase = previous
            problem = String(localized: "Couldn't reach your bot. Nothing was sent. Try again.")
        } catch {
            if choice == .once {
                shownText = attempted
                phase = .failed(reason: nil)
            } else {
                phase = previous
                problem = String(localized: "Couldn't cancel this. Nothing was sent. Try again.")
            }
        }
    }

    private func settle(_ refusal: HeldDraftRefusal, choice: HeldDraftChoice, attempted: String, edit: String, previous: Phase) {
        switch refusal.reason {
        case "already_sent": phase = .sent(at: nil)
        case "already_cancelled", "discarded": phase = .cancelled
        case "expired": phase = .expired
        case "invalid_edit":
            phase = .editing
            editText = edit
            problem = refusal.message
        case "invalid", "unviewable":
            phase = previous == .editing ? .waiting : previous
            blocksSend = true
            problem = refusal.message
        case "send_failed":
            shownText = attempted
            phase = .failed(reason: refusal.sendFailureReason)
        default:
            switch refusal.state {
            case "sent": phase = .sent(at: nil)
            case "cancelled": phase = .cancelled
            case "failed" where choice == .once:
                shownText = attempted
                phase = .failed(reason: refusal.sendFailureReason)
            default: phase = .unavailable(refusal.message)
            }
        }
    }
}

extension HeldDraftSheetModel {
    public var statusLine: String? {
        switch phase {
        case .sending: inFlight == .deny ? String(localized: "Cancelling…") : String(localized: "Sending…")
        case .sent(let at?): String(localized: "Sent once, \(at.formatted(date: .omitted, time: .shortened))")
        case .sent(nil): String(localized: "Sent once")
        case .failed(let reason): Self.failureLine(reason: reason, channel: draft.channelName)
        case .cancelled: String(localized: "Not sent. Cancelled.")
        case .expired: String(localized: "This draft waited too long. Ask the bot to write it again.")
        case .unavailable(let message): message
        case .waiting, .editing: nil
        }
    }

    public var detailLine: String? {
        switch phase {
        case .sent: String(localized: "\(draft.channelName) confirmed it. It cannot be sent again.")
        default: nil
        }
    }

    static func failureLine(reason: String?, channel: String) -> String {
        guard let reason else {
            return String(localized: "Not sent. It may or may not have gone out, check before sending again.")
        }
        return String(localized: "Not sent. \(channel) said: \(reason). It may or may not have gone out; check \(channel) before sending again.")
    }
}
