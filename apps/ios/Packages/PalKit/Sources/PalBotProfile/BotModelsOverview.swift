import Foundation
import Observation
import PalProtocol

public struct BotModelReading: Sendable, Equatable {
    public let model: String?
    public let effort: String?

    public init(model: String?, effort: String?) {
        self.model = ReasoningEffort.clean(model)
        self.effort = ReasoningEffort.clean(effort)
    }

    public var modelText: String { model ?? ReasoningEffort.unknown }
    public var effortText: String { ReasoningEffort.title(effort) }
    public var cloudEffortText: String { ReasoningEffort.cloudTitle(effort) }
}

public struct BotModelsRow: Sendable, Equatable, Identifiable {
    public let name: String
    public let displayName: String
    public let chat: BotModelReading
    public let cloud: BotModelReading?

    public init(name: String, displayName: String, chat: BotModelReading, cloud: BotModelReading? = nil) {
        self.name = name
        self.displayName = displayName
        self.chat = chat
        self.cloud = cloud
    }

    public var id: String { name }
}

struct BotModelsOverviewWire: Decodable {
    struct Profile: Decodable {
        let name: String
        let displayName: String?
        let model: String?

        enum CodingKeys: String, CodingKey {
            case name, model
            case displayName = "display_name"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            displayName = try? container.decodeIfPresent(String.self, forKey: .displayName)
            model = try? container.decodeIfPresent(String.self, forKey: .model)
        }
    }

    let profiles: [Profile]
}

public struct BotModelsOverviewClient: Sendable {
    private let gateway: BotsGateway

    public init(gateway: BotsGateway) {
        self.gateway = gateway
    }

    public func rows() async throws -> [BotModelsRow] {
        let profiles: [BotModelsOverviewWire.Profile]
        do {
            let result = try await gateway.call("profiles.list", ["include_sessions": false])
            profiles = try gateway.decoded(BotModelsOverviewWire.self, result).profiles
        } catch {
            throw BotsError.surface(error)
        }
        let gateway = gateway
        let efforts = await withTaskGroup(of: (String, String?).self) { group in
            for profile in profiles {
                group.addTask {
                    let effort = try? await BotModelClient(gateway: gateway, profile: profile.name).effort()
                    return (profile.name, effort)
                }
            }
            var found: [String: String] = [:]
            for await (name, effort) in group {
                if let effort { found[name] = effort }
            }
            return found
        }
        return profiles.map { profile in
            BotModelsRow(
                name: profile.name,
                displayName: ReasoningEffort.clean(profile.displayName) ?? profile.name,
                chat: BotModelReading(model: profile.model, effort: efforts[profile.name]))
        }
    }
}

@MainActor
@Observable
public final class BotModelsOverviewModel {
    public enum Phase: Sendable, Equatable {
        case loading
        case ready
        case failed
    }

    public private(set) var phase = Phase.loading
    public private(set) var rows: [BotModelsRow] = []
    @ObservationIgnored private let client: BotModelsOverviewClient

    public init(client: BotModelsOverviewClient) {
        self.client = client
    }

    public func load() async {
        do {
            rows = try await client.rows()
            phase = .ready
        } catch {
            if phase != .ready { phase = .failed }
        }
    }
}
