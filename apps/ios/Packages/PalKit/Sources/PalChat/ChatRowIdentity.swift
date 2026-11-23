import Foundation

public struct ChatRowIdentity: Sendable {
    private var aliases: [RowKey: String] = [:]

    public init() {}

    public mutating func ids(for rows: [ChatTimelineRow], outboxIDs: Set<String>, forwarded: [RowKey: RowKey]) -> [String] {
        let origins = Self.origins(of: forwarded)
        var used: Set<String> = []
        return rows.map { row in
            let candidate = resolve(row, outboxIDs: outboxIDs, origins: origins)
            let id = used.contains(candidate) ? row.id.description : candidate
            used.insert(id)
            return id
        }
    }

    private mutating func resolve(_ row: ChatTimelineRow, outboxIDs: Set<String>, origins: [RowKey: RowKey]) -> String {
        if let alias = aliases[row.id] { return alias }
        let id = outboxIDs.contains(row.item.id) ? row.item.id : originAlias(of: row.id, origins: origins)
        aliases[row.id] = id
        return id
    }

    private func originAlias(of key: RowKey, origins: [RowKey: RowKey]) -> String {
        var current = key
        var hops = 0
        while let live = origins[current], hops <= origins.count {
            current = live
            hops += 1
        }
        return aliases[current] ?? current.description
    }

    private static func origins(of forwarded: [RowKey: RowKey]) -> [RowKey: RowKey] {
        Dictionary(forwarded.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
    }
}
