import Foundation
import PalProtocol
import PalTransport

public enum SpeechMemoryArea: String, Sendable, Equatable, CaseIterable {
    case tts
    case memory
}

public struct SpeechMemoryProvider: Sendable, Equatable, Identifiable, Decodable {
    public let id: String
    public let name: String
    public let description: String?
    public let keyName: String?
    public let keyRequired: Bool
    public let keySet: Bool
    public let canRemove: Bool
    public let ready: Bool
    public let selectable: Bool
    public let note: String?

    public init(
        id: String, name: String, description: String? = nil, keyName: String? = nil, keyRequired: Bool = false,
        keySet: Bool = false, canRemove: Bool = false, ready: Bool = false, selectable: Bool = true, note: String? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.keyName = keyName
        self.keyRequired = keyRequired
        self.keySet = keySet
        self.canRemove = canRemove
        self.ready = ready
        self.selectable = selectable
        self.note = note
    }

    enum CodingKeys: String, CodingKey {
        case id, name, description, ready, selectable, note
        case keyName = "key_name"
        case keyRequired = "key_required"
        case keySet = "key_set"
        case canRemove = "can_remove"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description).flatMap(Self.nonEmpty)
        keyName = try container.decodeIfPresent(String.self, forKey: .keyName).flatMap(Self.nonEmpty)
        keyRequired = try container.decodeIfPresent(Bool.self, forKey: .keyRequired) ?? false
        keySet = try container.decodeIfPresent(Bool.self, forKey: .keySet) ?? false
        canRemove = try container.decodeIfPresent(Bool.self, forKey: .canRemove) ?? false
        ready = try container.decodeIfPresent(Bool.self, forKey: .ready) ?? false
        selectable = try container.decodeIfPresent(Bool.self, forKey: .selectable) ?? true
        note = try container.decodeIfPresent(String.self, forKey: .note).flatMap(Self.nonEmpty)
    }

    private static func nonEmpty(_ value: String) -> String? { value.isEmpty ? nil : value }

    public var statusWord: String { keySet ? "Set" : "Not set" }
}

public struct SpeechVoiceOption: Sendable, Equatable, Identifiable, Decodable {
    public let id: String
    public let label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

public struct SpeechVoice: Sendable, Equatable, Decodable {
    public let current: String
    public let options: [SpeechVoiceOption]

    public init(current: String, options: [SpeechVoiceOption]) {
        self.current = current
        self.options = options
    }
}

public struct SpeechProviderGroup: Sendable, Equatable, Decodable {
    public let selected: String
    public let providers: [SpeechMemoryProvider]
    public let voice: SpeechVoice?

    public init(selected: String, providers: [SpeechMemoryProvider], voice: SpeechVoice? = nil) {
        self.selected = selected
        self.providers = providers
        self.voice = voice
    }
}

public struct SpeechMemorySettings: Sendable, Equatable, Decodable {
    public let tts: SpeechProviderGroup
    public let memory: SpeechProviderGroup

    public init(tts: SpeechProviderGroup, memory: SpeechProviderGroup) {
        self.tts = tts
        self.memory = memory
    }

    public func group(_ area: SpeechMemoryArea) -> SpeechProviderGroup {
        switch area {
        case .tts: tts
        case .memory: memory
        }
    }
}

public enum SpeechMemoryChoice: Sendable, Equatable {
    case saved(SpeechMemorySettings?)
    case needsKey(String)
    case unsupported(String)
    case invalid(String)
    case failed(String)
}

struct SpeechMemoryChoiceWire: Decodable {
    let outcome: String
    let reason: String?
    let settings: SpeechMemorySettings?
}

public struct SpeechMemoryClient: Sendable {
    private let gateway: BotsGateway
    private let capabilities: CapabilitiesService
    private let profile: String

    public init(gateway: BotsGateway, profile: String) {
        self.gateway = gateway
        self.capabilities = CapabilitiesService(gateway: gateway)
        self.profile = profile
    }

    public func settings() async throws -> SpeechMemorySettings {
        do {
            let result = try await gateway.scoped("speech_memory.settings.get", profile: profile)
            return try gateway.decoded(SpeechMemorySettings.self, result)
        } catch {
            throw BotsError.surface(error)
        }
    }

    public func choose(_ area: SpeechMemoryArea, provider: String, voice: String? = nil) async -> SpeechMemoryChoice {
        var params: [String: JSONValue] = ["area": .string(area.rawValue), "provider": .string(provider)]
        if let voice { params["voice"] = .string(voice) }
        do {
            let result = try await gateway.scoped("speech_memory.settings.set", profile: profile, params)
            let wire = try gateway.decoded(SpeechMemoryChoiceWire.self, result)
            let reason = wire.reason ?? Self.couldNotSave
            switch wire.outcome {
            case "saved": return .saved(wire.settings)
            case "needs_key": return .needsKey(reason)
            case "unsupported": return .unsupported(reason)
            case "invalid": return .invalid(reason)
            default: return .failed(reason)
            }
        } catch {
            return .failed(Self.couldNotSave)
        }
    }

    public func setKey(_ keyName: String, to value: SecretString) async throws {
        _ = try await capabilities.setKey(keyName, to: value, profile: profile)
    }

    public func removeKey(_ keyName: String) async throws {
        _ = try await capabilities.setKey(keyName, to: nil, profile: profile)
    }

    static let couldNotSave = "Couldn't save that choice. Nothing changed."
}
