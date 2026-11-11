import Foundation
import PalDiagnostics
import PalProtocol

public struct BotAdmin: Sendable {
    public static let maximumTitleLength = 60

    private let gateway: RosterGateway
    private let writer: BotMetaWriter
    private let diagnostics: Diagnostics

    public init(gateway: RosterGateway, diagnostics: Diagnostics = .silent) {
        self.gateway = gateway
        self.diagnostics = diagnostics
        writer = BotMetaWriter(gateway: gateway, diagnostics: diagnostics)
    }

    @discardableResult
    public func setPinned(_ profile: String, pinned: Bool) async throws -> BotMeta {
        try await setFlag(BotMeta.pinnedKey, on: profile, to: pinned, failure: "pin change failed")
    }

    @discardableResult
    public func setHidden(_ profile: String, hidden: Bool) async throws -> BotMeta {
        try await setFlag(BotMeta.hiddenKey, on: profile, to: hidden, failure: "visibility change failed")
    }

    public func rename(_ profile: String, isPrimary: Bool, to proposed: String) async throws {
        let title = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= Self.maximumTitleLength else { throw BotAdminError.invalidName }
        do {
            try await writer.update(profile) { fields in
                var next = fields
                next["title"] = .string(title)
                return next
            }
            if isPrimary {
                _ = try await gateway.call("profiles.rename", ["name": .string(profile), "new_name": .string(title)])
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            diagnostics.warning("roster", "rename failed: \(Diagnostics.describe(error))")
            throw BotAdminError.classify(error)
        }
    }

    public func delete(_ profile: String) async throws {
        do {
            let result = try await gateway.call("profiles.delete", ["name": .string(profile)])
            guard result["ok"]?.boolValue == true else { throw BotAdminError.rejected }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            diagnostics.warning("roster", "delete failed: \(Diagnostics.describe(error))")
            throw BotAdminError.classify(error)
        }
    }

    private func setFlag(_ key: String, on profile: String, to value: Bool, failure: String) async throws -> BotMeta {
        do {
            return try await writer.update(profile) { fields in
                var next = fields
                next[key] = .bool(value)
                return next
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            diagnostics.warning("roster", "\(failure): \(Diagnostics.describe(error))")
            throw BotAdminError.classify(error)
        }
    }

    public func makePrimary(_ profile: String) async throws {
        do {
            let result = try await gateway.call("profiles.set_primary", ["name": .string(profile)])
            guard result["ok"]?.boolValue == true else { throw BotAdminError.rejected }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            diagnostics.warning("roster", "make primary failed: \(Diagnostics.describe(error))")
            throw BotAdminError.classify(error)
        }
    }
}
