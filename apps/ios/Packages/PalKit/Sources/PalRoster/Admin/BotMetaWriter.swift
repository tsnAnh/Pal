import Foundation
import PalDiagnostics
import PalProtocol

public struct BotMetaWriter: Sendable {
    public static let defaultAttempts = 3

    private let gateway: RosterGateway
    private let attempts: Int
    private let diagnostics: Diagnostics

    public init(gateway: RosterGateway, attempts: Int = BotMetaWriter.defaultAttempts, diagnostics: Diagnostics = .silent) {
        self.gateway = gateway
        self.attempts = max(1, attempts)
        self.diagnostics = diagnostics
    }

    public func read(_ profile: String) async throws -> BotMeta? {
        try await listing().profiles.first { $0.name == profile }?.botMeta
    }

    public func listing() async throws -> (profiles: [RosterProfile], capabilities: RosterCapabilities) {
        let result = try await gateway.call("profiles.list", ["include_sessions": false])
        let rows = result["profiles"]?.arrayValue ?? []
        return (rows.compactMap(RosterProfile.init), RosterCapabilities(listResult: result))
    }

    @discardableResult
    public func update(
        _ profile: String,
        change: @Sendable ([String: JSONValue]) -> [String: JSONValue]
    ) async throws -> BotMeta {
        for attempt in 1...attempts {
            try Task.checkCancellation()
            guard let current = try await read(profile) else { throw BotAdminError.botNotFound }
            let next = change(current.fields)
            if next == current.fields { return current }
            var params: [String: JSONValue] = [
                "name": .string(profile),
                "ui_meta": [BotMeta.namespace: .object(next)],
            ]
            if let revision = current.revision {
                params["ui_meta_expected_revisions"] = [BotMeta.namespace: .int(revision)]
            }
            let result = try await gateway.call("profiles.configure", .object(params))
            let applied = result["applied"]
            if let conflicts = applied?["ui_meta_conflicts"]?.objectValue, !conflicts.isEmpty {
                diagnostics.info("roster", "ui_meta revision conflict on attempt \(attempt)")
                continue
            }
            if applied?["ui_meta"]?.boolValue == false || result["ok"]?.boolValue == false {
                throw BotAdminError.rejected
            }
            let revision = applied?["ui_meta_revisions"]?[BotMeta.namespace]?.intValue ?? current.revision.map { $0 + 1 }
            return BotMeta(fields: next, revision: revision)
        }
        throw BotAdminError.conflict
    }
}
