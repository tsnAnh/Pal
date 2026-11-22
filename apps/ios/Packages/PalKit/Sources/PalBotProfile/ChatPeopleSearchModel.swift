import Foundation
import Observation
import PalProtocol

@MainActor
@Observable
public final class ChatPeopleSearchModel {
    public enum Phase: Equatable, Sendable {
        case loading
        case ready
        case failed
    }

    public static let debounce: Duration = .milliseconds(300)

    public private(set) var phase = Phase.loading
    public private(set) var people: [ChatPersonWire] = []
    public private(set) var picked: [ChatAudienceMemberWire]
    public private(set) var isLoadingMore = false
    public private(set) var isCommitting = false
    public var query = "" {
        didSet { if query != oldValue { scheduleSearch() } }
    }

    private let members: ChatMembersModel
    private var nextCursor: String?
    @ObservationIgnored private var search: Task<Void, Never>?

    public init(members: ChatMembersModel, picked: [ChatAudienceMemberWire]) {
        self.members = members
        self.picked = picked
    }

    public var hasMore: Bool { nextCursor != nil }

    public func isPicked(_ id: String) -> Bool { picked.contains { $0.id == id } }

    public func start() async {
        await fetch(replacing: true)
    }

    public func retry() async {
        phase = .loading
        await fetch(replacing: true)
    }

    public func toggle(_ person: ChatPersonWire) {
        if let index = picked.firstIndex(where: { $0.id == person.id }) {
            picked.remove(at: index)
        } else {
            picked.append(ChatAudienceMemberWire(id: person.id, name: person.shownName))
        }
    }

    public func loadMoreIfNeeded(after person: ChatPersonWire) async {
        guard person.id == people.last?.id, nextCursor != nil, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        await fetch(replacing: false)
    }

    public func commit() async -> Bool {
        guard !isCommitting else { return false }
        isCommitting = true
        defer { isCommitting = false }
        await members.setMembers(picked.map(\.id))
        return members.notice == nil
    }

    private func scheduleSearch() {
        search?.cancel()
        search = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled, let self else { return }
            await fetch(replacing: true)
        }
    }

    private func fetch(replacing: Bool) async {
        let asked = query.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let page = try await members.people(query: asked, cursor: replacing ? nil : nextCursor)
            guard asked == query.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            people = replacing ? page.people : people + page.people.filter { added in !people.contains { $0.id == added.id } }
            nextCursor = page.nextCursor
            phase = .ready
        } catch is CancellationError {
        } catch {
            if replacing { phase = .failed }
        }
    }
}
