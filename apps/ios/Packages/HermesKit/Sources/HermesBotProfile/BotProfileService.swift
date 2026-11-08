import CryptoKit
import Foundation
import HermesDiagnostics
import HermesProtocol

public struct BotProfileService: Sendable {
    public static let notificationsKey = "bot_mode.notifications"
    public static let defaultAttempts = 3

    private let gateway: BotsGateway
    private let attempts: Int
    private let diagnostics: Diagnostics

    public init(gateway: BotsGateway, attempts: Int = BotProfileService.defaultAttempts, diagnostics: Diagnostics = .silent) {
        self.gateway = gateway
        self.attempts = max(1, attempts)
        self.diagnostics = diagnostics
    }

    public func profile(named name: String) async throws -> BotProfile {
        do {
            let result = try await gateway.call("profiles.list", ["include_sessions": false, "include_routines": true])
            let list = try gateway.decoded(ProfilesListWire.self, result)
            guard let row = list.profiles.first(where: { $0.name == name }) else { throw BotsError.notFound }
            return BotProfile(row: row)
        } catch {
            throw BotsError.surface(error)
        }
    }

    public func notificationsEnabled(for name: String) async throws -> Bool {
        do {
            let result = try await gateway.scoped("config.get", profile: name, ["key": .string(Self.notificationsKey)])
            let value = try gateway.decoded(ConfigValueWire.self, result).value
            return Self.isOn(value)
        } catch {
            throw BotsError.surface(error)
        }
    }

    public func setNotifications(_ enabled: Bool, for name: String) async throws {
        do {
            _ = try await gateway.scoped("config.set", profile: name, [
                "key": .string(Self.notificationsKey),
                "value": .string(enabled ? "on" : "off"),
            ])
        } catch {
            diagnostics.warning("bots", "notification change failed: \(Diagnostics.describe(error))")
            throw BotsError.surface(error)
        }
    }

    static func isOn(_ value: JSONValue?) -> Bool {
        switch value {
        case .string(let text): text.lowercased() != "off"
        case .bool(let flag): flag
        default: true
        }
    }

    public func makePrimary(_ name: String) async throws {
        do {
            let result = try await gateway.call("profiles.set_primary", ["name": .string(name)])
            guard try gateway.decoded(ProfilesSetPrimaryWire.self, result).ok else { throw BotsError.rejected(reason: nil) }
        } catch {
            diagnostics.warning("bots", "make primary failed: \(Diagnostics.describe(error))")
            throw BotsError.surface(error)
        }
    }

    public func rename(_ profile: BotProfile, to proposed: String) async throws {
        let title = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= Self.maximumTitleLength else { throw BotsError.rejected(reason: "invalid_name") }
        do {
            try await updateMeta(profile.name) { fields in
                var next = fields
                next["title"] = .string(title)
                return next
            }
            if profile.isPrimary {
                _ = try await gateway.call("profiles.rename", ["name": .string(profile.name), "new_name": .string(title)])
            }
        } catch {
            diagnostics.warning("bots", "rename failed: \(Diagnostics.describe(error))")
            throw BotsError.surface(error)
        }
    }

    public func updateLook(_ name: String, shape: String, colorHex: String) async throws {
        do {
            try await updateMeta(name) { fields in
                var next = fields
                next["shape"] = .string(shape)
                next["color"] = .string(colorHex)
                next["custom"] = .bool(true)
                return next
            }
        } catch {
            diagnostics.warning("bots", "look change failed: \(Diagnostics.describe(error))")
            throw BotsError.surface(error)
        }
    }

    public func computerStatus(for name: String) async throws -> ComputerStatus {
        do {
            let result = try await gateway.scoped("display.status", profile: name)
            return ComputerStatus(try gateway.decoded(DisplayStatusWire.self, result))
        } catch {
            throw BotsError.surface(error)
        }
    }

    public func exportTemplate(for name: String) async throws -> TemplateFile {
        do {
            let result = try await gateway.call("profiles.template.export", ["name": .string(name)])
            let wire = try gateway.decoded(ProfileTemplateWire.self, result)
            return try Self.verifiedTemplate(wire)
        } catch {
            throw BotsError.surface(error)
        }
    }

    static func verifiedTemplate(_ wire: ProfileTemplateWire) throws -> TemplateFile {
        guard let data = Data(base64Encoded: wire.data), !data.isEmpty, data.count == wire.size else {
            throw BotsError.invalidResponse
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == wire.sha256.lowercased() else { throw BotsError.invalidResponse }
        let leaf = (wire.filename as NSString).lastPathComponent
        guard !leaf.isEmpty, leaf != ".", leaf != ".." else { throw BotsError.invalidResponse }
        return TemplateFile(filename: leaf, data: data)
    }

    static let maximumTitleLength = 60

    private func updateMeta(_ name: String, change: @Sendable ([String: JSONValue]) -> [String: JSONValue]) async throws {
        for attempt in 1...attempts {
            try Task.checkCancellation()
            let current = try await profile(named: name).meta
            let next = change(current.fields)
            if next == current.fields { return }
            var params: [String: JSONValue] = [
                "name": .string(name),
                "ui_meta": [BotMeta.namespace: .object(next)],
            ]
            if let revision = current.revision {
                params["ui_meta_expected_revisions"] = [BotMeta.namespace: .int(revision)]
            }
            let result = try await gateway.call("profiles.configure", params)
            let applied = try gateway.decoded(ProfilesConfigureWire.self, result).applied
            if let conflicts = applied?.uiMetaConflicts, !conflicts.isEmpty {
                diagnostics.info("bots", "ui_meta revision conflict on attempt \(attempt)")
                continue
            }
            guard applied?.uiMeta != false else { throw BotsError.rejected(reason: nil) }
            return
        }
        throw BotsError.conflict
    }
}
