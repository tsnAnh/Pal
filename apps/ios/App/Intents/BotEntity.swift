import AppIntents
import Foundation

struct BotEntity: AppEntity, IndexedEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Bot"
    static let defaultQuery = BotEntityQuery()

    let id: String

    @Property(title: "Name")
    var name: String

    @Property(title: "Is Default")
    var isDefault: Bool

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    init(id: String, name: String, isDefault: Bool) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
    }

    init(_ profile: BotProfile) {
        self.init(id: profile.name, name: profile.title, isDefault: profile.isDefault ?? false)
    }

    init(_ row: BotRow) {
        self.init(id: row.name, name: row.displayName, isDefault: row.isDefault)
    }
}

struct BotEntityQuery: EntityStringQuery, EnumerableEntityQuery {
    @Dependency var environment: IntentEnvironment

    func allEntities() async throws -> [BotEntity] {
        try await environment.bots().sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    func suggestedEntities() async throws -> [BotEntity] {
        try await allEntities()
    }

    func entities(for identifiers: [String]) async throws -> [BotEntity] {
        let wanted = Set(identifiers)
        return try await allEntities().filter { wanted.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [BotEntity] {
        let needle = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return try await allEntities() }
        return try await allEntities().filter { $0.name.localizedStandardContains(needle) || $0.id.localizedStandardContains(needle) }
    }
}
