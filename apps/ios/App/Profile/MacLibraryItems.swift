import Foundation
import PalBotProfile

struct MacLibraryHeaderItem: Equatable {
    let id: String
    let title: String
}

struct MacLibraryRowItem: Equatable {
    let entry: LibraryEntry
    let subtitle: String
    let groupID: String
    let isFirst: Bool
    let isLast: Bool
}

enum MacLibraryItem: Identifiable, Equatable {
    case header(MacLibraryHeaderItem)
    case row(MacLibraryRowItem)

    var id: String {
        switch self {
        case .header(let header): "header-\(header.id)"
        case .row(let row): "row-\(row.entry.id)"
        }
    }
}

enum MacLibraryItems {
    static func make(
        _ entries: [LibraryEntry],
        subtitle: (LibraryEntry) -> String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [MacLibraryItem] {
        let today = entries.filter { calendar.isDate($0.occurredAt, inSameDayAs: now) }
        let older = entries.filter { !calendar.isDate($0.occurredAt, inSameDayAs: now) }
        var items: [MacLibraryItem] = []
        items.reserveCapacity(entries.count + 2)
        append(today, id: "today", title: String(localized: "Today"), subtitle: subtitle, to: &items)
        append(older, id: "older", title: String(localized: "Older"), subtitle: subtitle, to: &items)
        return items
    }

    private static func append(
        _ entries: [LibraryEntry],
        id: String,
        title: String,
        subtitle: (LibraryEntry) -> String,
        to items: inout [MacLibraryItem]
    ) {
        guard let last = entries.indices.last else { return }
        items.append(.header(MacLibraryHeaderItem(id: id, title: title)))
        for index in entries.indices {
            let entry = entries[index]
            items.append(.row(MacLibraryRowItem(
                entry: entry,
                subtitle: subtitle(entry),
                groupID: id,
                isFirst: index == entries.startIndex,
                isLast: index == last
            )))
        }
    }
}

struct MacItemsCache {
    let version: Int
    let day: Date
    let items: [MacLibraryItem]
}
