import Foundation
import PalProtocol

public struct ModelCapability: Sendable, Hashable, Decodable {
    public let reasoning: Bool?
    public let canDisableReasoning: Bool?

    public init(reasoning: Bool? = nil, canDisableReasoning: Bool? = nil) {
        self.reasoning = reasoning
        self.canDisableReasoning = canDisableReasoning
    }

    enum CodingKeys: String, CodingKey {
        case reasoning
        case canDisableReasoning = "can_disable_reasoning"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reasoning = try? container.decodeIfPresent(Bool.self, forKey: .reasoning)
        canDisableReasoning = try? container.decodeIfPresent(Bool.self, forKey: .canDisableReasoning)
    }
}

public enum EffortOptions: Sendable, Equatable {
    case levels([String])
    case unsupported
    case unknown
}

public enum ReasoningEffort {
    static let ladder = ["minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
    static let aboveCloudCap: Set<String> = ["xhigh", "max", "ultra"]
    public static let unknown = "unknown"

    public static func options(for capability: ModelCapability?) -> EffortOptions {
        guard let capability, let reasoning = capability.reasoning else { return .unknown }
        guard reasoning else { return .unsupported }
        return .levels((capability.canDisableReasoning == true ? ["none"] : []) + ladder)
    }

    public static func title(_ effort: String?) -> String {
        guard let effort, !effort.isEmpty else { return unknown }
        return effort == "none" ? "Off" : effort.prefix(1).uppercased() + effort.dropFirst()
    }

    public static func isAboveCloudCap(_ effort: String?) -> Bool {
        effort.map { aboveCloudCap.contains($0.lowercased()) } ?? false
    }

    public static func cloudTitle(_ effort: String?) -> String {
        isAboveCloudCap(effort) ? "\(title(effort)) (above the allowed cap)" : title(effort)
    }

    static func clean(_ text: String?) -> String? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension BotModelClient {
    public func effort() async throws -> String? {
        do {
            let result = try await gateway.scoped("config.get", profile: profile, ["key": .string("reasoning")])
            return ReasoningEffort.clean(try gateway.decoded(ConfigValueWire.self, result).value?.stringValue)
        } catch {
            throw BotsError.surface(error)
        }
    }

    public func setEffort(_ effort: String) async -> BotModelWrite {
        let params: [String: JSONValue] = ["key": .string("reasoning"), "value": .string(effort), "scope": .string("global")]
        do {
            let result = try await gateway.scoped("config.set", profile: profile, params)
            let echoed = try gateway.decoded(ConfigValueWire.self, result).value?.stringValue
            return echoed == effort ? .saved : .failed(Self.couldNotSaveEffort)
        } catch {
            return .failed(Self.couldNotSaveEffort)
        }
    }

    static let couldNotSaveEffort = "Couldn't change the reasoning effort. Nothing was changed."
}
