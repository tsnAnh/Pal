import Foundation
import PalBotProfile
import PalProtocol

extension GatewayChatInstallClient: ChatMemberClient {
    func audience(_ scope: ChatInstallScope) async throws -> ChatAudienceWire {
        try decode(ChatAudienceWire.self, await perform("chat.audience.get", scope), "chat.audience.get")
    }

    func setAudience(_ scope: ChatInstallScope, _ change: ChatAudienceChange) async throws -> ChatAudienceWire {
        var extra: [String: JSONValue] = [
            "policy": .string(change.policy.rawValue), "expected_revision": .int(change.expectedRevision),
        ]
        if let members = change.members { extra["members"] = .array(members.map(JSONValue.string)) }
        if let include = change.includeRestricted { extra["include_restricted"] = .bool(include) }
        return try decode(ChatAudienceWire.self, await perform("chat.audience.set", scope, extra), "chat.audience.set")
    }

    func people(_ scope: ChatInstallScope, query: String, cursor: String?) async throws -> ChatPeoplePageWire {
        var extra: [String: JSONValue] = ["query": .string(query)]
        if let cursor { extra["cursor"] = .string(cursor) }
        return try decode(ChatPeoplePageWire.self, await perform("chat.people.list", scope, extra), "chat.people.list")
    }

    func report(_ scope: ChatInstallScope) async throws -> ChatReportDestinationWire {
        try decode(ChatReportResult.self, await perform("chat.report.get", scope), "chat.report.get").destination
    }

    func setReport(_ scope: ChatInstallScope, _ destination: ChatReportDestinationWire) async throws -> ChatReportDestinationWire {
        var wire: [String: JSONValue] = ["kind": .string(destination.kind.rawValue)]
        if let spaceId = destination.spaceId { wire["space_id"] = .string(spaceId) }
        let result = try await perform("chat.report.set", scope, ["destination": .object(wire)])
        return try decode(ChatReportResult.self, result, "chat.report.set").destination
    }

    func leave(_ scope: ChatInstallScope, spaceId: String) async throws -> ChatSpaceLeaveOutcome {
        let result = try await perform("chat.space.leave", scope, ["space_id": .string(spaceId)])
        return try decode(ChatSpaceLeaveResult.self, result, "chat.space.leave").outcome
    }

    func desk() async throws -> [ChatDeskItemWire] {
        let kinds: JSONValue = .array([.string(ChatDeskItemKind.handoff.rawValue), .string(ChatDeskItemKind.send.rawValue)])
        return try decode(ChatDeskListResult.self, await perform("chat.desk.list", nil, ["kinds": kinds]), "chat.desk.list").items
    }

    func decide(itemId: String, choice: ChatDeskChoice, expectedRevision: Int) async throws -> ChatDeskItemWire {
        let result = try await perform(
            "chat.desk.decide", nil,
            ["item_id": .string(itemId), "choice": .string(choice.rawValue), "expected_revision": .int(expectedRevision)]
        )
        return try decode(ChatDeskDecideResult.self, result, "chat.desk.decide").item
    }
}
