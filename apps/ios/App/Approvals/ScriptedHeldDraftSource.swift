import Foundation
import PalChat
import PalProtocol
import PalTransport

enum HeldDraftFixture {
    static let argument = "-hermes-test-held-drafts"

    static func source(arguments: [String]) -> (any HeldDraftSource)? {
        guard let index = arguments.firstIndex(of: argument), arguments.indices.contains(index + 1) else { return nil }
        return ScriptedHeldDraftSource(profile: arguments[index + 1])
    }
}

actor ScriptedHeldDraftSource: HeldDraftSource {
    private enum Fate {
        case sent
        case cancelled
    }

    private static let samID = "00000000000000000000000000000a01"
    private static let danaID = "00000000000000000000000000000a02"
    private static let lateID = "00000000000000000000000000000a03"

    private let profile: String
    private var settled: [String: Fate] = [:]
    private var danaAttempts = 0

    init(profile: String) {
        self.profile = profile
    }

    private var all: [HeldDraft] {
        [
            HeldDraft(
                id: Self.samID, channel: "telegram", recipient: "Sam", text: "Running late, start without me.",
                expiresAt: Date().addingTimeInterval(7200)
            ),
            HeldDraft(id: Self.danaID, channel: "email", recipient: "Dana", text: "Lunch at noon?\nI booked the corner table."),
            HeldDraft(id: Self.lateID, channel: "telegram", recipient: "Lee", text: "Too late now.", standing: .expired, canSend: false),
        ]
    }

    func drafts(profile: String) async throws -> [HeldDraft] {
        guard profile == self.profile else { return [] }
        return all.filter { settled[$0.id] == nil }
    }

    func answer(profile: String, draftID: String, choice: HeldDraftChoice, editedText: String?) async throws -> HeldDraftOutcome {
        guard profile == self.profile, all.contains(where: { $0.id == draftID }) else {
            throw Self.refusal("not_found", state: nil, message: "This draft no longer exists.")
        }
        switch settled[draftID] {
        case .sent?: throw Self.refusal("already_sent", state: "sent", message: "This draft was already sent.")
        case .cancelled?: throw Self.refusal("already_cancelled", state: "cancelled", message: "This draft was cancelled and was not sent.")
        case nil: break
        }
        try await Task.sleep(for: .milliseconds(400))
        if choice == .deny {
            settled[draftID] = .cancelled
            return .cancelled
        }
        if draftID == Self.danaID {
            danaAttempts += 1
            if danaAttempts == 1 {
                throw Self.refusal(
                    "send_failed", state: "failed",
                    message: "The message was NOT sent: rate limited. It is still waiting for approval; approve it again to retry."
                )
            }
        }
        settled[draftID] = .sent
        return .sent
    }

    private static func refusal(_ reason: String, state: String?, message: String) -> any Error {
        var data: [String: JSONValue] = ["reason": .string(reason)]
        if let state { data["state"] = .string(state) }
        return GatewayTransportError.rpc(RPCError(code: HeldDraftRefusal.wireCode, message: message, data: .object(data)))
    }
}
