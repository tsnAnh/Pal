import CryptoKit
import Foundation
import HermesDiagnostics
import HermesProtocol
import HermesRoster

public struct BotProfileService: Sendable {
    public static let notificationsKey = "bot_mode.notifications"

    private let gateway: BotsGateway
    private let admin: BotAdmin
    private let writer: BotMetaWriter
    private let diagnostics: Diagnostics

    public init(gateway: BotsGateway, attempts: Int = BotMetaWriter.defaultAttempts, diagnostics: Diagnostics = .silent) {
        self.gateway = gateway
        self.diagnostics = diagnostics
        admin = BotAdmin(gateway: gateway.roster, diagnostics: diagnostics)
        writer = BotMetaWriter(gateway: gateway.roster, attempts: attempts, diagnostics: diagnostics)
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
            try await admin.makePrimary(name)
        } catch {
            throw BotsError.surface(error)
        }
    }

    public func rename(_ profile: BotProfile, to proposed: String) async throws {
        let title = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= Self.maximumTitleLength else { throw BotsError.rejected(reason: "invalid_name") }
        do {
            try await writer.update(profile.name) { fields in
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
            try await writer.update(name) { fields in
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
}
