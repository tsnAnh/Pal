import Foundation
import HermesProtocol
import HermesTransport

public enum ModelProviderKind: Sendable, Equatable {
    case apiKey
    case deviceCode
    case unsupported
    case unknown

    init(wire: String) {
        switch wire {
        case "api_key": self = .apiKey
        case "device_code": self = .deviceCode
        case "unsupported": self = .unsupported
        default: self = .unknown
        }
    }
}

public enum ModelProviderState: Sendable, Equatable {
    case set
    case notSet
    case expired
    case unsupported
    case unknown

    init(wire: String) {
        switch wire {
        case "set": self = .set
        case "not_set": self = .notSet
        case "expired": self = .expired
        case "unsupported": self = .unsupported
        default: self = .unknown
        }
    }
}

public enum ModelProviderScope: Sendable, Equatable {
    case profile
    case account
    case unknown

    init(wire: String) {
        switch wire {
        case "profile": self = .profile
        case "account": self = .account
        default: self = .unknown
        }
    }
}

public struct ModelProvider: Sendable, Equatable, Identifiable, Decodable {
    public let id: String
    public let name: String
    public let kind: ModelProviderKind
    public let state: ModelProviderState
    public let scope: ModelProviderScope
    public let baseURLEditable: Bool
    public let baseURL: String?
    public let defaultBaseURL: String?
    public let reason: String?
    public let canRemove: Bool

    public init(
        id: String, name: String, kind: ModelProviderKind, state: ModelProviderState, scope: ModelProviderScope = .profile,
        baseURLEditable: Bool = false, baseURL: String? = nil, defaultBaseURL: String? = nil, reason: String? = nil,
        canRemove: Bool = false
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.state = state
        self.scope = scope
        self.baseURLEditable = baseURLEditable
        self.baseURL = baseURL
        self.defaultBaseURL = defaultBaseURL
        self.reason = reason
        self.canRemove = canRemove
    }

    enum CodingKeys: String, CodingKey {
        case id, name, kind, state, scope, reason
        case baseURLEditable = "base_url_editable"
        case baseURL = "base_url"
        case defaultBaseURL = "default_base_url"
        case canRemove = "can_remove"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        kind = ModelProviderKind(wire: try container.decode(String.self, forKey: .kind))
        state = ModelProviderState(wire: try container.decode(String.self, forKey: .state))
        scope = ModelProviderScope(wire: try container.decodeIfPresent(String.self, forKey: .scope) ?? "")
        baseURLEditable = try container.decodeIfPresent(Bool.self, forKey: .baseURLEditable) ?? false
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL).flatMap(Self.nonEmpty)
        defaultBaseURL = try container.decodeIfPresent(String.self, forKey: .defaultBaseURL).flatMap(Self.nonEmpty)
        reason = try container.decodeIfPresent(String.self, forKey: .reason).flatMap(Self.nonEmpty)
        canRemove = try container.decodeIfPresent(Bool.self, forKey: .canRemove) ?? false
    }

    private static func nonEmpty(_ value: String) -> String? { value.isEmpty ? nil : value }

    public var canSignIn: Bool {
        switch kind {
        case .apiKey, .deviceCode: state != .unsupported
        case .unsupported, .unknown: false
        }
    }
}

public enum ModelProviderRemoval: Sendable, Equatable {
    case removed(ModelProvider?)
    case nothingToRemove(ModelProvider?)
    case stillSet(String, ModelProvider?)
    case refused(String)
    case unsupported(String)
    case failed(String)
}

public enum ModelProviderBaseURLChange: Sendable, Equatable {
    case saved(ModelProvider?)
    case reset(ModelProvider?)
    case invalid(String)
    case unsupported(String)
    case failed(String)
}

public enum ModelProviderSignInStart: Sendable, Equatable {
    case started(requestID: String?)
    case unsupported(String)
    case refused(String)
    case unavailable(String)
}

struct ModelProvidersListWire: Decodable {
    let providers: [ModelProvider]
}

struct ModelProviderActionWire: Decodable {
    let outcome: String
    let reason: String?
    let provider: ModelProvider?
    let requestID: String?

    enum CodingKeys: String, CodingKey {
        case outcome, reason, provider
        case requestID = "request_id"
    }
}

public struct ModelProvidersClient: Sendable {
    public static let serviceKey = "provider:"

    private let gateway: BotsGateway
    private let profile: String?

    public init(gateway: BotsGateway, profile: String? = nil) {
        self.gateway = gateway
        self.profile = profile
    }

    public func list() async throws -> [ModelProvider] {
        do {
            let result = try await gateway.call("model.providers.list", scoped([:]))
            return try gateway.decoded(ModelProvidersListWire.self, result).providers
        } catch {
            throw BotsError.surface(error)
        }
    }

    public func remove(_ provider: String) async -> ModelProviderRemoval {
        do {
            let action = try await perform("model.providers.remove", ["provider": .string(provider)])
            let reason = action.reason ?? Self.couldNotRemove
            switch action.outcome {
            case "removed": return .removed(action.provider)
            case "nothing_to_remove": return .nothingToRemove(action.provider)
            case "still_set": return .stillSet(reason, action.provider)
            case "refused": return .refused(reason)
            case "unsupported": return .unsupported(reason)
            default: return .failed(reason)
            }
        } catch {
            return .failed(Self.couldNotRemove)
        }
    }

    public func setBaseURL(_ provider: String, to baseURL: String?) async -> ModelProviderBaseURLChange {
        do {
            let value: JSONValue = baseURL.map(JSONValue.string) ?? .null
            let action = try await perform("model.providers.set_base_url", ["provider": .string(provider), "base_url": value])
            let reason = action.reason ?? Self.couldNotSaveAddress
            switch action.outcome {
            case "saved": return .saved(action.provider)
            case "reset": return .reset(action.provider)
            case "invalid": return .invalid(reason)
            case "unsupported": return .unsupported(reason)
            default: return .failed(reason)
            }
        } catch {
            return .failed(Self.couldNotSaveAddress)
        }
    }

    public func beginSignIn(_ provider: String) async -> ModelProviderSignInStart {
        do {
            let result = try await gateway.call(ServiceSignInWire.beginMethod, ["service": .string(Self.serviceKey + provider)])
            let action = try gateway.decoded(ModelProviderActionWire.self, result)
            let reason = action.reason ?? Self.couldNotStart
            switch action.outcome {
            case "started": return .started(requestID: action.requestID.flatMap { $0.isEmpty ? nil : $0 })
            case "unsupported": return .unsupported(reason)
            case "refused": return .refused(reason)
            default: return .unavailable(reason)
            }
        } catch {
            return .unavailable(Self.couldNotStart)
        }
    }

    private func perform(_ method: String, _ params: [String: JSONValue]) async throws -> ModelProviderActionWire {
        let result = try await gateway.call(method, scoped(params))
        return try gateway.decoded(ModelProviderActionWire.self, result)
    }

    private func scoped(_ params: [String: JSONValue]) -> [String: JSONValue] {
        guard let profile, !profile.isEmpty else { return params }
        var merged = params
        merged["profile"] = .string(profile)
        return merged
    }

    static let couldNotRemove = "Couldn't remove that. Try again."
    static let couldNotSaveAddress = "Couldn't save that address. Try again."
    static let couldNotStart = "Couldn't start sign-in. Try again in a moment."
}
