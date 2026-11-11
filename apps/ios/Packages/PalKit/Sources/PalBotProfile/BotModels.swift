import Foundation
import PalProtocol

public struct ModelChoice: Sendable, Hashable, Identifiable {
    public let provider: String
    public let model: String

    public init(provider: String, model: String) {
        self.provider = provider
        self.model = model
    }

    public var id: String { "\(provider)/\(model)" }

    var wire: JSONValue { ["provider": .string(provider), "model": .string(model)] }
}

public struct ModelCatalogProvider: Sendable, Hashable, Identifiable, Decodable {
    public let id: String
    public let name: String
    public let models: [String]
    public let hasCredential: Bool

    public init(id: String, name: String, models: [String], hasCredential: Bool = true) {
        self.id = id
        self.name = name
        self.models = models
        self.hasCredential = hasCredential
    }

    enum CodingKeys: String, CodingKey {
        case id = "slug"
        case name, models, authenticated
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? id
        models = try container.decodeIfPresent([String].self, forKey: .models) ?? []
        hasCredential = try container.decodeIfPresent(Bool.self, forKey: .authenticated) ?? true
    }
}

public struct BotModelSettings: Sendable, Equatable {
    public var current: ModelChoice?
    public var fallbacks: [ModelChoice]

    public init(current: ModelChoice?, fallbacks: [ModelChoice]) {
        self.current = current
        self.fallbacks = fallbacks
    }
}

public enum BotModelWrite: Sendable, Equatable {
    case saved
    case needsConfirmation(String)
    case failed(String)
}

struct BotModelSettingsWire: Decodable {
    struct Pin: Decodable {
        let provider: String?
        let `default`: String?
    }

    struct Entry: Decodable {
        let provider: String
        let model: String
    }

    let model: Pin?
    let fallbackProviders: [Entry]?

    enum CodingKeys: String, CodingKey {
        case model
        case fallbackProviders = "fallback_providers"
    }
}

struct ModelCatalogWire: Decodable {
    let providers: [ModelCatalogProvider]
}

struct BotModelWriteWire: Decodable {
    struct Applied: Decodable {
        let model: Bool?
        let fallbackProviders: Bool?

        enum CodingKeys: String, CodingKey {
            case model
            case fallbackProviders = "fallback_providers"
        }
    }

    let applied: Applied?
    let confirmRequired: Bool?
    let confirmMessage: String?

    enum CodingKeys: String, CodingKey {
        case applied
        case confirmRequired = "confirm_required"
        case confirmMessage = "confirm_message"
    }
}

public struct BotModelClient: Sendable {
    private let gateway: BotsGateway
    private let profile: String

    public init(gateway: BotsGateway, profile: String) {
        self.gateway = gateway
        self.profile = profile
    }

    public func settings() async throws -> BotModelSettings {
        do {
            let result = try await gateway.call("profiles.describe", ["name": .string(profile)])
            let wire = try gateway.decoded(BotModelSettingsWire.self, result)
            let current = wire.model.flatMap { pin -> ModelChoice? in
                guard let provider = pin.provider, !provider.isEmpty, let model = pin.default, !model.isEmpty else { return nil }
                return ModelChoice(provider: provider, model: model)
            }
            return BotModelSettings(
                current: current,
                fallbacks: (wire.fallbackProviders ?? []).map { ModelChoice(provider: $0.provider, model: $0.model) })
        } catch {
            throw BotsError.surface(error)
        }
    }

    public func catalog() async throws -> [ModelCatalogProvider] {
        do {
            let result = try await gateway.scoped("model.options", profile: profile, ["include_unconfigured": .bool(true)])
            return try gateway.decoded(ModelCatalogWire.self, result).providers
        } catch {
            throw BotsError.surface(error)
        }
    }

    public func setModel(_ choice: ModelChoice, confirmed: Bool) async -> BotModelWrite {
        var params: [String: JSONValue] = [
            "name": .string(profile), "provider": .string(choice.provider), "model": .string(choice.model),
        ]
        if confirmed { params["confirm_expensive_model"] = .bool(true) }
        do {
            let wire = try gateway.decoded(BotModelWriteWire.self, try await gateway.call("profiles.configure", params))
            if wire.confirmRequired == true { return .needsConfirmation(wire.confirmMessage ?? Self.confirmFallback) }
            return wire.applied?.model == true ? .saved : .failed(Self.couldNotSaveModel)
        } catch {
            return .failed(Self.couldNotSaveModel)
        }
    }

    public func setFallbacks(_ fallbacks: [ModelChoice]) async -> BotModelWrite {
        let params: [String: JSONValue] = ["name": .string(profile), "fallback_providers": .array(fallbacks.map(\.wire))]
        do {
            let wire = try gateway.decoded(BotModelWriteWire.self, try await gateway.call("profiles.configure", params))
            return wire.applied?.fallbackProviders == true ? .saved : .failed(Self.couldNotSaveFallbacks)
        } catch {
            return .failed(Self.couldNotSaveFallbacks)
        }
    }

    static let couldNotSaveModel = "Couldn't change the model. Nothing was changed."
    static let couldNotSaveFallbacks = "Couldn't save the backup models. Nothing was changed."
    static let confirmFallback = "This model may cost more or share data differently. Use it anyway?"
}
