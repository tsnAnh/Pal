import Foundation
import PalProtocol
import PalTransport

public struct BotPersona: Sendable, Equatable, Codable {
    public static let maximumDescriptionLength = 280
    public static let maximumSoulLength = 20_000

    public var description: String
    public var soul: String

    public init(description: String = "", soul: String = "") {
        self.description = description
        self.soul = soul
    }
}

public enum BotPersonaField: Sendable, Hashable {
    case description
    case soul
}

public struct BotPersonaEdit: Sendable, Equatable {
    public var description: String
    public var soul: String

    public init(description: String, soul: String) {
        self.description = description
        self.soul = soul
    }

    public func changedFields(from original: BotPersona) -> Set<BotPersonaField> {
        var changed: Set<BotPersonaField> = []
        if Self.normalized(description) != Self.normalized(original.description) { changed.insert(.description) }
        if soul != original.soul { changed.insert(.soul) }
        return changed
    }

    public func isValid(from original: BotPersona) -> Bool {
        let changed = changedFields(from: original)
        if changed.contains(.description), Self.normalized(description).count > BotPersona.maximumDescriptionLength { return false }
        if changed.contains(.soul), soul.count > BotPersona.maximumSoulLength || soul.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }
        return true
    }

    public static func normalized(_ description: String) -> String {
        description.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct BotPersonaSave: Sendable, Equatable {
    public var saved: Set<BotPersonaField>
    public var failed: Set<BotPersonaField>

    public init(saved: Set<BotPersonaField> = [], failed: Set<BotPersonaField> = []) {
        self.saved = saved
        self.failed = failed
    }
}

public enum BotDescribeResult: Sendable, Equatable {
    case written(String)
    case alreadyDescribed
    case notOwner
    case failed
}

public struct BotPersonaClient: Sendable {
    static let alreadyDescribedCode = 4102
    static let notOwnerCode = 4403

    let gateway: BotsGateway
    let profile: String

    public init(gateway: BotsGateway, profile: String) {
        self.gateway = gateway
        self.profile = profile
    }

    public func load() async throws -> BotPersona {
        do {
            let result = try await gateway.call("profiles.describe", ["name": .string(profile)])
            guard result.objectValue != nil else { throw BotsError.invalidResponse }
            return BotPersona(
                description: result["description"]?.stringValue ?? "",
                soul: result["soul"]?.stringValue ?? ""
            )
        } catch {
            throw BotsError.surface(error)
        }
    }

    public func save(_ edit: BotPersonaEdit, changing fields: Set<BotPersonaField>) async -> BotPersonaSave {
        guard !fields.isEmpty else { return BotPersonaSave() }
        var params: [String: JSONValue] = ["name": .string(profile)]
        if fields.contains(.description) { params["description"] = .string(BotPersonaEdit.normalized(edit.description)) }
        if fields.contains(.soul) { params["soul"] = .string(edit.soul) }
        let applied: JSONValue?
        do {
            applied = try await gateway.call("profiles.configure", params)["applied"]
        } catch {
            return BotPersonaSave(failed: fields)
        }
        var outcome = BotPersonaSave()
        for field in fields {
            let key = field == .description ? "description" : "soul"
            if applied?[key]?.boolValue == true { outcome.saved.insert(field) } else { outcome.failed.insert(field) }
        }
        return outcome
    }

    public func describeAutomatically(overwrite: Bool) async -> BotDescribeResult {
        do {
            let result = try await gateway.call("profiles.describe_auto", ["name": .string(profile), "overwrite": .bool(overwrite)])
            guard let text = result["description"]?.stringValue, !BotPersonaEdit.normalized(text).isEmpty else { return .failed }
            return .written(BotPersonaEdit.normalized(text))
        } catch GatewayTransportError.rpc(let rpc) where rpc.code == Self.alreadyDescribedCode {
            return .alreadyDescribed
        } catch GatewayTransportError.rpc(let rpc) where rpc.code == Self.notOwnerCode {
            return .notOwner
        } catch {
            return .failed
        }
    }
}
