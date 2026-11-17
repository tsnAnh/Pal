import Foundation
import PalTransport

public struct KanbanBots: Sendable, Equatable {
    private let displayNames: [String: String]

    public init(displayNames: [String: String] = [:]) {
        self.displayNames = displayNames
    }

    public func name(for handle: String?) -> String? {
        guard let handle = handle?.trimmingCharacters(in: .whitespacesAndNewlines), !handle.isEmpty else { return nil }
        let display = displayNames[handle]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return display.isEmpty ? handle : display
    }

    public func sorted(_ handles: [String]) -> [String] {
        handles.sorted { (name(for: $0) ?? $0).localizedStandardCompare(name(for: $1) ?? $1) == .orderedAscending }
    }
}

public struct KanbanPullRequest: Sendable, Hashable {
    public enum State: Sendable, Hashable {
        case open
        case merged
        case checksFailing
    }

    public let state: State
    public let number: Int?

    public init(state: State, number: Int?) {
        self.state = state
        self.number = number
    }
}

extension KanbanCardRow {
    public var pullRequest: KanbanPullRequest? {
        guard let latest = pullRequests.max(by: { $0.evidenceID < $1.evidenceID }) else { return nil }
        let number = latest.url.flatMap { Int($0.lastPathComponent) }
        if hasMergedPullRequest { return KanbanPullRequest(state: .merged, number: number) }
        if detail?.ciAcceptance.state == .rejected { return KanbanPullRequest(state: .checksFailing, number: number) }
        return KanbanPullRequest(state: .open, number: number)
    }
}
