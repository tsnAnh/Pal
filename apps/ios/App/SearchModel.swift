import Foundation
import PalDiagnostics
import PalRoster
import Observation

@MainActor
@Observable
final class SearchModel {
    var query = "" {
        didSet { if query != oldValue { refresh() } }
    }

    var scope: SearchScope = .all {
        didSet { if scope != oldValue { refresh() } }
    }

    private(set) var state = SearchState()

    private let roster: RosterModel
    private let supported: Set<SearchScope>
    private let coordinator: SearchCoordinator
    private let requests: AsyncStream<Request>
    private let requestSink: AsyncStream<Request>.Continuation
    private var tasks: [Task<Void, Never>] = []

    private struct Request: Sendable {
        var query: String
        var sources: Set<SearchScope>
        var bots: [SearchBot]
    }

    init(roster: RosterModel, supported: [SearchScope]) {
        self.roster = roster
        self.supported = Set(supported)
        coordinator = SearchCoordinator(engine: SearchEngine(gateway: roster.gateway), diagnostics: .osLog())
        (requests, requestSink) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    func start() {
        guard tasks.isEmpty else { return }
        let coordinator = coordinator
        tasks.append(Task { [requests] in
            for await request in requests {
                await coordinator.update(query: request.query, sources: request.sources, bots: request.bots)
            }
        })
        tasks.append(Task { [weak self] in
            for await next in coordinator.states { self?.state = next }
        })
        refresh()
    }

    func stop() {
        requestSink.finish()
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        let coordinator = coordinator
        Task { await coordinator.stop() }
    }

    var items: [SearchItem] { state.items(for: scope) }

    var isLoading: Bool { state.isLoading(scope) }

    var hasFailures: Bool { !state.failedSources(in: scope).isEmpty }

    var isIdleQuery: Bool { query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func refresh() {
        requestSink.yield(Request(query: query, sources: Set(scope.sources).intersection(supported), bots: roster.searchBots))
    }
}
