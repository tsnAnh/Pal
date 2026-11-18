import Foundation
import PalTransport

public enum KanbanColumn: String, Sendable, CaseIterable, Identifiable {
    case backlog
    case ready
    case inProgress
    case blocked
    case review
    case done

    public var id: String { rawValue }

    public init(status: KanbanCardStatus) {
        switch status {
        case .triage, .todo, .scheduled, .unknown: self = .backlog
        case .ready: self = .ready
        case .running: self = .inProgress
        case .blocked: self = .blocked
        case .review: self = .review
        case .done, .archived: self = .done
        }
    }

    public var title: String {
        switch self {
        case .backlog: String(localized: "Backlog")
        case .ready: String(localized: "Ready")
        case .inProgress: String(localized: "In progress")
        case .blocked: String(localized: "Blocked")
        case .review: String(localized: "In review")
        case .done: String(localized: "Done")
        }
    }

    public var alwaysShown: Bool {
        switch self {
        case .backlog, .ready, .inProgress, .done: true
        case .blocked, .review: false
        }
    }
}

public struct KanbanCardRow: Sendable, Hashable, Identifiable {
    public let card: KanbanCard
    public let project: String?
    public let detail: KanbanCardDetail?

    public init(card: KanbanCard, project: String?, detail: KanbanCardDetail? = nil) {
        self.card = card
        self.project = project
        self.detail = detail
    }

    public var id: String { card.cardID }
    public var column: KanbanColumn { KanbanColumn(status: card.status) }
    public var displayTitle: String {
        let title = card.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? card.taskID : title
    }
    public var ref: String? { KanbanBody.ref(in: body) }
    public var bot: String? { card.assignee.flatMap { $0.isEmpty ? nil : $0 } }
    public var body: String? { detail?.body }
    public var evidenceCount: Int { detail?.evidence.count ?? 0 }
    public var pullRequests: [KanbanEvidence] {
        detail?.evidence.filter { $0.kind == .prPublished || $0.kind == .prMerged } ?? []
    }
    public var hasMergedPullRequest: Bool { pullRequests.contains { $0.kind == .prMerged } }
}

public struct KanbanFilter: Sendable, Equatable {
    public var text = ""
    public var project: String?
    public var bot: String?
    public var column: KanbanColumn?

    public init(text: String = "", project: String? = nil, bot: String? = nil, column: KanbanColumn? = nil) {
        self.text = text
        self.project = project
        self.bot = bot
        self.column = column
    }

    public var isActive: Bool {
        !terms.isEmpty || project != nil || bot != nil || column != nil
    }

    private var terms: [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    public func matches(_ row: KanbanCardRow) -> Bool {
        if let project, row.project != project { return false }
        if let bot, row.bot != bot { return false }
        if let column, row.column != column { return false }
        return terms.allSatisfy { term in
            row.displayTitle.localizedStandardContains(term)
                || (row.body?.localizedStandardContains(term) ?? false)
                || Self.refMatches(row.ref, term: term)
        }
    }

    private static func refMatches(_ ref: String?, term: String) -> Bool {
        let wanted = KanbanRef.normalized(term)
        guard let ref, !wanted.isEmpty else { return false }
        return KanbanRef.normalized(ref).hasPrefix(wanted)
    }
}

public struct KanbanColumnLayout: Sendable, Equatable, Identifiable {
    public let column: KanbanColumn
    public let rows: [KanbanCardRow]
    public let total: Int

    public var id: String { column.id }
}

public struct KanbanBoardLayout: Sendable, Equatable {
    public let columns: [KanbanColumnLayout]
    public let projects: [String]
    public let bots: [String]
    public let totalCards: Int
    public let matchingCards: Int

    public init(rows: [KanbanCardRow], filter: KanbanFilter) {
        let matching = rows.filter(filter.matches)
        let byColumn = Dictionary(grouping: matching, by: \.column)
        let totals = Dictionary(grouping: rows, by: \.column).mapValues(\.count)
        columns = KanbanColumn.allCases.compactMap { column in
            let total = totals[column] ?? 0
            guard column.alwaysShown || total > 0 else { return nil }
            return KanbanColumnLayout(column: column, rows: Self.sorted(byColumn[column] ?? [], in: column), total: total)
        }
        projects = Set(rows.compactMap(\.project)).sorted()
        bots = Set(rows.compactMap(\.bot)).sorted()
        totalCards = rows.count
        matchingCards = matching.count
    }

    public static func rows(session: KanbanSession, board: String) -> [KanbanCardRow] {
        guard let cache = session.cache(board) else { return [] }
        let project = cache.board?.projectID
        return cache.cards.values.map { card in
            KanbanCardRow(card: card, project: project, detail: session.detail(board: board, taskID: card.taskID))
        }
    }

    private static func sorted(_ rows: [KanbanCardRow], in column: KanbanColumn) -> [KanbanCardRow] {
        rows.sorted { lhs, rhs in
            if column == .done {
                let left = lhs.card.completedAt ?? 0
                let right = rhs.card.completedAt ?? 0
                if left != right { return left > right }
            } else if (lhs.card.priority ?? 0) != (rhs.card.priority ?? 0) {
                return (lhs.card.priority ?? 0) > (rhs.card.priority ?? 0)
            }
            return (lhs.card.createdAt ?? 0, lhs.card.taskID) < (rhs.card.createdAt ?? 0, rhs.card.taskID)
        }
    }
}
