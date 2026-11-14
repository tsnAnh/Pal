import Foundation
import Observation
import PalProtocol
import PalTransport

public struct BotKeyRow: Sendable, Equatable, Identifiable {
    public let name: String
    public let label: String
    public let isSet: Bool

    public var id: String { name }
    public var statusWord: String { isSet ? "Set" : "Not set" }

    public init(name: String, label: String, isSet: Bool) {
        self.name = name
        self.label = label
        self.isSet = isSet
    }
}

public struct BotKeyGroup: Sendable, Equatable, Identifiable {
    public let id: String
    public let label: String
    public let keys: [BotKeyRow]

    public init(id: String, label: String, keys: [BotKeyRow]) {
        self.id = id
        self.label = label
        self.keys = keys
    }
}

private struct BotKeysWire: Decodable {
    struct Key: Decodable {
        let name: String
        let label: String?
        let isSet: Bool?

        enum CodingKeys: String, CodingKey {
            case name, label
            case isSet = "is_set"
        }
    }

    struct Group: Decodable {
        let id: String
        let label: String?
        let keys: [Key]?
    }

    let groups: [Group]

    var parsed: [BotKeyGroup] {
        groups.compactMap { group in
            let rows = (group.keys ?? []).compactMap { key -> BotKeyRow? in
                let name = key.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return nil }
                let label = key.label?.trimmingCharacters(in: .whitespacesAndNewlines)
                return BotKeyRow(name: name, label: label.flatMap { $0.isEmpty ? nil : $0 } ?? name, isSet: key.isSet ?? false)
            }
            guard !rows.isEmpty else { return nil }
            let label = group.label?.trimmingCharacters(in: .whitespacesAndNewlines)
            return BotKeyGroup(id: group.id, label: label.flatMap { $0.isEmpty ? nil : $0 } ?? group.id, keys: rows)
        }
    }
}

public struct BotKeysService: Sendable {
    private let gateway: BotsGateway

    public init(gateway: BotsGateway) {
        self.gateway = gateway
    }

    public func status(profile: String) async throws -> [BotKeyGroup] {
        do {
            let result = try await gateway.scoped("bot_keys.status", profile: profile)
            return try gateway.decoded(BotKeysWire.self, result).parsed
        } catch {
            throw BotsError.surface(error)
        }
    }

    public func setKey(_ keyName: String, to value: SecretString?, profile: String) async throws -> [BotKeyGroup] {
        do {
            let result = try await gateway.scoped("bot_keys.set", profile: profile, [
                "key_name": .string(keyName), "value": value.map { .string($0.reveal()) } ?? .null,
            ])
            return try gateway.decoded(BotKeysWire.self, result).parsed
        } catch {
            throw BotsError.surface(error)
        }
    }
}

@MainActor
@Observable
public final class BotKeysModel {
    public enum Phase: Sendable, Equatable {
        case loading
        case ready
        case failed
    }

    public enum EntryState: Sendable, Equatable {
        case idle
        case submitting
        case failed(String)
    }

    public enum Notice: Sendable, Equatable {
        case working(String)
        case saved(String)
        case failed(String)
    }

    public private(set) var phase = Phase.loading
    public private(set) var groups: [BotKeyGroup] = [] {
        didSet { surfaces.remember(groups, surfaceKey) }
    }
    public private(set) var entryState = EntryState.idle
    public private(set) var notices: [String: Notice] = [:]
    public var entry: BotKeyRow?
    public var pendingRemoval: BotKeyRow?

    @ObservationIgnored private let service: BotKeysService
    @ObservationIgnored private let profile: String
    @ObservationIgnored private let surfaces: SurfaceCache
    @ObservationIgnored private let surfaceKey: SurfaceKey

    public init(service: BotKeysService, profile: String, surfaces: SurfaceCache) {
        self.service = service
        self.profile = profile
        self.surfaces = surfaces
        surfaceKey = .screen("bot-keys", bot: profile)
        if let held = surfaces.remembered([BotKeyGroup].self, surfaceKey) {
            groups = held
            phase = .ready
        }
    }

    public func notice(_ row: BotKeyRow) -> Notice? { notices[row.name] }

    public func isWorking(_ row: BotKeyRow) -> Bool {
        if case .working = notices[row.name] { true } else { false }
    }

    public func load() async {
        if groups.isEmpty { phase = .loading }
        do {
            groups = try await service.status(profile: profile)
            phase = .ready
        } catch is CancellationError {
        } catch {
            if groups.isEmpty { phase = .failed }
        }
    }

    public func begin(_ row: BotKeyRow) {
        entryState = .idle
        entry = row
    }

    public func cancel() {
        entry = nil
        entryState = .idle
    }

    public func submit(_ value: String) async {
        guard let row = entry, entryState != .submitting else { return }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            entryState = .failed("Paste a key to save.")
            return
        }
        entryState = .submitting
        do {
            groups = try await service.setKey(row.name, to: SecretString(trimmed), profile: profile)
        } catch is CancellationError {
            entryState = .idle
            return
        } catch {
            entryState = .failed("Couldn't save the key. The old one was kept. Check it and try again.")
            return
        }
        notices[row.name] = .saved("Key saved.")
        cancel()
    }

    public func remove(_ row: BotKeyRow) async {
        pendingRemoval = nil
        guard row.isSet, !isWorking(row) else { return }
        notices[row.name] = .working("Removing…")
        do {
            groups = try await service.setKey(row.name, to: nil, profile: profile)
        } catch is CancellationError {
            notices[row.name] = nil
            return
        } catch {
            notices[row.name] = .failed("Couldn't remove the key. It was kept.")
            return
        }
        notices[row.name] = .saved("Key removed.")
    }
}
