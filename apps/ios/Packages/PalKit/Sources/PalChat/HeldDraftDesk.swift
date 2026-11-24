import Foundation
import PalProtocol

public protocol HeldDraftSource: Sendable {
    func drafts(profile: String) async throws -> [HeldDraft]
    func answer(profile: String, draftID: String, choice: HeldDraftChoice, editedText: String?) async throws -> HeldDraftOutcome
}

public struct HeldDraftDesk: HeldDraftSource {
    private let connector: any ChatConnector
    private let resolver = BotChatResolver()

    public init(connector: any ChatConnector) {
        self.connector = connector
    }

    public func drafts(profile: String) async throws -> [HeldDraft] {
        do {
            return try await withBotChat(profile) { api, sessionID in try await api.heldDrafts(sessionID: sessionID) }
        } catch ChatError.noBotChat {
            return []
        }
    }

    public func answer(profile: String, draftID: String, choice: HeldDraftChoice, editedText: String?) async throws -> HeldDraftOutcome {
        do {
            return try await withBotChat(profile) { api, sessionID in
                try await api.respondToHeldDraft(sessionID: sessionID, draftID: draftID, choice: choice, editedText: editedText)
            }
        } catch ChatError.noBotChat {
            throw HeldDraftDeskError.unreachable
        }
    }

    private func withBotChat<T: Sendable>(_ profile: String, _ body: (SessionAPI, String) async throws -> T) async throws -> T {
        let connection = try await connector.connect()
        let api = SessionAPI(connection: connection, profile: profile)
        let result: T
        do {
            guard let row = try await resolver.lookup(api) else { throw ChatError.noBotChat }
            let snapshot = try await api.resume(sessionID: BotChatResolver.target(of: row), omitMessages: true)
            result = try await body(api, snapshot.sessionID)
        } catch {
            await connection.close()
            throw error
        }
        await connection.close()
        return result
    }
}

extension SessionAPI {
    func heldDrafts(sessionID: String) async throws -> [HeldDraft] {
        let result = try await call("approval.pending", ["session_id": .string(sessionID)])
        guard let cards = result["approvals"]?.arrayValue else { throw ChatError.unexpectedResponse(method: "approval.pending") }
        return cards.compactMap { HeldDraft(card: $0) }
    }

    func respondToHeldDraft(sessionID: String, draftID: String, choice: HeldDraftChoice, editedText: String?) async throws -> HeldDraftOutcome {
        var params: [String: JSONValue] = [
            "session_id": .string(sessionID),
            "prompt_id": .string(HeldDraft.promptPrefix + draftID),
            "choice": .string(choice.rawValue),
        ]
        if choice == .once, let editedText { params["edited_text"] = .string(editedText) }
        let result = try await call("approval.respond", params)
        switch (choice, result["state"]?.stringValue) {
        case (.once, "sent"): return .sent
        case (.deny, "cancelled"): return .cancelled
        default: throw ChatError.unexpectedResponse(method: "approval.respond")
        }
    }
}
