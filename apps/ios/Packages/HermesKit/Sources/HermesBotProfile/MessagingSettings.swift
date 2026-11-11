import Foundation
import HermesProtocol
import HermesTransport

public enum MessagingSettingKind: String, Sendable, Equatable {
    case allowlist
    case homeChannel = "home_channel"
}

public struct MessagingSetting: Sendable, Equatable, Identifiable {
    public let key: String
    public let kind: MessagingSettingKind
    public let label: String
    public let values: [String]

    public var id: String { key }
    public var text: String { values.joined(separator: ", ") }

    init?(_ wire: MessagingSettingsFieldWire) {
        guard let kind = MessagingSettingKind(rawValue: wire.kind) else { return nil }
        key = wire.key
        self.kind = kind
        label = wire.label
        values = wire.values
    }
}

public struct MessagingCredential: Sendable, Equatable, Identifiable {
    public let key: String
    public let label: String
    public let isSet: Bool

    public var id: String { key }

    public init(key: String, label: String, isSet: Bool) {
        self.key = key
        self.label = label
        self.isSet = isSet
    }
}

public struct MessagingPlatform: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let enabled: Bool
    public let configured: Bool
    public let settings: [MessagingSetting]
    public let credentials: [MessagingCredential]

    public var displayName: String { name.isEmpty ? id : name }

    init(_ wire: MessagingSettingsPlatformWire) {
        id = wire.id
        name = wire.name
        enabled = wire.enabled
        configured = wire.configured
        settings = wire.fields.compactMap(MessagingSetting.init)
        credentials = wire.secrets.map { MessagingCredential(key: $0.key, label: $0.label, isSet: $0.isSet) }
    }
}

public struct MessagingSettingsSnapshot: Sendable, Equatable {
    public let gatewayRunning: Bool
    public let platforms: [MessagingPlatform]
}

public struct MessagingSaveResult: Sendable, Equatable {
    public let platform: MessagingPlatform
    public let changed: Bool
    public let restartNeeded: Bool
}

public enum MessagingSettingsError: Error, Sendable, Equatable {
    case invalid(fields: [String: String])
}

public enum MessagingSettingsText {
    public static func values(_ text: String) -> [String] {
        let separators = CharacterSet(charactersIn: ",;").union(.whitespacesAndNewlines)
        return text.components(separatedBy: separators).filter { !$0.isEmpty }
    }
}

public struct MessagingSettingsService: Sendable {
    static let invalidCode = 4101

    private let gateway: BotsGateway

    public init(gateway: BotsGateway) {
        self.gateway = gateway
    }

    public func load(profile: String) async throws -> MessagingSettingsSnapshot {
        do {
            let result = try await gateway.scoped("messaging.settings.get", profile: profile)
            let wire = try gateway.decoded(MessagingSettingsGetWire.self, result)
            return MessagingSettingsSnapshot(gatewayRunning: wire.gatewayRunning, platforms: wire.platforms.map(MessagingPlatform.init))
        } catch {
            throw BotsError.surface(error)
        }
    }

    public func save(profile: String, platform: String, enabled: Bool?, values: [String: [String]]) async throws -> MessagingSaveResult {
        var params: [String: JSONValue] = ["platform": .string(platform)]
        if let enabled { params["enabled"] = .bool(enabled) }
        if !values.isEmpty {
            params["fields"] = .object(values.mapValues { .array($0.map(JSONValue.string)) })
        }
        do {
            let result = try await gateway.scoped("messaging.settings.update", profile: profile, params)
            let wire = try gateway.decoded(MessagingSettingsUpdateWire.self, result)
            return MessagingSaveResult(platform: MessagingPlatform(wire.settings), changed: wire.changed, restartNeeded: wire.restartNeeded)
        } catch GatewayTransportError.rpc(let rpc) where rpc.code == Self.invalidCode {
            throw MessagingSettingsError.invalid(fields: Self.fieldErrors(rpc))
        } catch {
            throw BotsError.surface(error)
        }
    }

    static func fieldErrors(_ rpc: RPCError) -> [String: String] {
        guard let object = rpc.data?["fields"]?.objectValue else { return [:] }
        return object.compactMapValues(\.stringValue)
    }
}
