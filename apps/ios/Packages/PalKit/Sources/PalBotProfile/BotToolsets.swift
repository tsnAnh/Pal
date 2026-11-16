import Foundation
import Observation
import PalProtocol

public struct Toolset: Sendable, Hashable, Identifiable {
    public let name: String
    public let label: String
    public let summary: String
    public let toolCount: Int
    public let isEnabled: Bool

    public init(name: String, label: String, summary: String = "", toolCount: Int = 0, isEnabled: Bool = false) {
        self.name = name
        self.label = label
        self.summary = summary
        self.toolCount = toolCount
        self.isEnabled = isEnabled
    }

    public var id: String { name }
}

public struct BotToolsets: Sendable, Equatable {
    public var items: [Toolset]
    public var isPinned: Bool

    public init(items: [Toolset], isPinned: Bool) {
        self.items = items
        self.isPinned = isPinned
    }
}

struct BotToolsetsWire: Decodable {
    struct Row: Decodable {
        let name: String
        let label: String?
        let description: String?
        let toolCount: Int?
        let enabled: Bool?

        enum CodingKeys: String, CodingKey {
            case name, label, description, enabled
            case toolCount = "tool_count"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            label = try? container.decodeIfPresent(String.self, forKey: .label)
            description = try? container.decodeIfPresent(String.self, forKey: .description)
            toolCount = try? container.decodeIfPresent(Int.self, forKey: .toolCount)
            enabled = try? container.decodeIfPresent(Bool.self, forKey: .enabled)
        }
    }

    private struct Skipped: Decodable {
        init(from decoder: any Decoder) throws {}
    }

    let rows: [Row]?
    let pinned: Bool?

    enum CodingKeys: String, CodingKey {
        case toolsets
        case pinned = "toolsets_pinned"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pinned = try? container.decodeIfPresent(Bool.self, forKey: .pinned)
        guard container.contains(.toolsets), var list = try? container.nestedUnkeyedContainer(forKey: .toolsets) else {
            rows = nil
            return
        }
        var decoded: [Row] = []
        while !list.isAtEnd {
            if let row = try? list.decode(Row.self) {
                decoded.append(row)
            } else {
                _ = try? list.decode(Skipped.self)
            }
        }
        rows = decoded
    }

    func toolsets() -> BotToolsets? {
        guard let rows else { return nil }
        var seen = Set<String>()
        let items = rows.compactMap { row -> Toolset? in
            let name = row.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seen.insert(name).inserted else { return nil }
            let label = ReasoningEffort.clean(row.label) ?? name
            return Toolset(
                name: name, label: label, summary: ReasoningEffort.clean(row.description) ?? "",
                toolCount: max(row.toolCount ?? 0, 0), isEnabled: row.enabled ?? false)
        }
        return BotToolsets(items: items, isPinned: pinned ?? false)
    }
}

struct BotToolsetsWriteWire: Decodable {
    struct Applied: Decodable {
        let toolsets: Bool?
    }

    let applied: Applied?
}

public struct BotToolsetsClient: Sendable {
    let gateway: BotsGateway
    let profile: String

    public init(gateway: BotsGateway, profile: String) {
        self.gateway = gateway
        self.profile = profile
    }

    public func load() async throws -> BotToolsets? {
        do {
            let result = try await gateway.call("profiles.describe", ["name": .string(profile)])
            return try gateway.decoded(BotToolsetsWire.self, result).toolsets()
        } catch {
            throw BotsError.surface(error)
        }
    }

    public func save(enabled names: [String]) async -> Bool {
        let params: [String: JSONValue] = ["name": .string(profile), "enabled_toolsets": .array(names.map { .string($0) })]
        do {
            let wire = try gateway.decoded(BotToolsetsWriteWire.self, try await gateway.call("profiles.configure", params))
            return wire.applied?.toolsets == true
        } catch {
            return false
        }
    }
}

@MainActor
@Observable
public final class BotToolsetsModel {
    public enum Phase: Sendable, Equatable {
        case loading
        case ready
        case unavailable
        case failed
    }

    public enum Save: Sendable, Equatable {
        case idle
        case saving
        case saved
        case failed
    }

    public private(set) var phase = Phase.loading
    public private(set) var items: [Toolset] = []
    public private(set) var isPinned = false
    public private(set) var save = Save.idle
    public private(set) var draft: Set<String> = []
    private var saved: Set<String> = []

    @ObservationIgnored private let client: BotToolsetsClient

    public init(client: BotToolsetsClient) {
        self.client = client
    }

    public var isSaving: Bool { save == .saving }

    public var hasChanges: Bool { draft != saved }

    public var canSave: Bool { phase == .ready && hasChanges && !draft.isEmpty && !isSaving }

    public var needsSelection: Bool { phase == .ready && hasChanges && draft.isEmpty }

    public var enabledNames: [String] { items.map(\.name).filter { draft.contains($0) } }

    public func isOn(_ name: String) -> Bool { draft.contains(name) }

    public func load() async {
        guard !isSaving else { return }
        if phase == .failed { phase = .loading }
        await refresh()
    }

    private func refresh() async {
        do {
            guard let toolsets = try await client.load() else {
                phase = .unavailable
                return
            }
            items = toolsets.items
            isPinned = toolsets.isPinned
            saved = Set(toolsets.items.filter(\.isEnabled).map(\.name))
            draft = saved
            phase = .ready
        } catch {
            if phase != .ready { phase = .failed }
        }
    }

    public func toggle(_ name: String, on: Bool) {
        guard phase == .ready, !isSaving, items.contains(where: { $0.name == name }) else { return }
        if on { draft.insert(name) } else { draft.remove(name) }
        if save != .idle { save = .idle }
    }

    public func commit() async {
        guard canSave else { return }
        await write(enabledNames, pinned: true)
    }

    public func useStandardSet() async {
        guard phase == .ready, !isSaving else { return }
        await write([], pinned: false)
    }

    private func write(_ names: [String], pinned: Bool) async {
        save = .saving
        guard await client.save(enabled: names) else {
            draft = saved
            save = .failed
            return
        }
        save = .saved
        if pinned {
            isPinned = true
            saved = Set(names)
            draft = saved
        } else {
            phase = .loading
            await refresh()
        }
    }
}
