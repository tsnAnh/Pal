import Foundation
import PalProtocol

public struct ModelCapability: Sendable, Hashable, Decodable {
    public let reasoning: Bool?
    public let canDisableReasoning: Bool?
    public let efforts: [String]?

    public init(reasoning: Bool? = nil, canDisableReasoning: Bool? = nil, efforts: [String]? = nil) {
        self.reasoning = reasoning
        self.canDisableReasoning = canDisableReasoning
        self.efforts = ReasoningEffort.reported(efforts)
    }

    enum CodingKeys: String, CodingKey {
        case reasoning
        case canDisableReasoning = "can_disable_reasoning"
        case efforts
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reasoning = try? container.decodeIfPresent(Bool.self, forKey: .reasoning)
        canDisableReasoning = try? container.decodeIfPresent(Bool.self, forKey: .canDisableReasoning)
        efforts = ReasoningEffort.reported(try? container.decodeIfPresent([String].self, forKey: .efforts))
    }
}

public enum EffortOptions: Sendable, Equatable {
    case levels([String])
    case unsupported
    case unknown
}

public enum ReasoningEffort {
    static let aboveCloudCap: Set<String> = ["xhigh", "max", "ultra"]
    public static let unknown = "unknown"

    public static func options(for capability: ModelCapability?) -> EffortOptions {
        guard let capability else { return .unknown }
        if capability.reasoning == false { return .unsupported }
        guard let efforts = capability.efforts else { return .unknown }
        let offered = (capability.canDisableReasoning == true ? ["none"] : []) + efforts.filter { $0 != "none" }
        return offered.isEmpty ? .unknown : .levels(offered)
    }

    public static func choices(_ levels: [String], keeping current: String?) -> [String] {
        guard let current = clean(current), !levels.contains(current) else { return levels }
        return levels + [current]
    }

    static func reported(_ efforts: [String]?) -> [String]? {
        guard let efforts else { return nil }
        var seen = Set<String>()
        let levels = efforts.compactMap(clean).filter { seen.insert($0).inserted }
        return levels.isEmpty ? nil : levels
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
