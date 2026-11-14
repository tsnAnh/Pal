import Foundation
import PalDiagnostics
import PalProtocol
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
            for await next in coordinator.states { self?.receive(next) }
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

    private struct Recent: Sendable {
        var order: [String] = []
        var states: [String: SearchState] = [:]
    }

    private static let recentKey = SurfaceKey.screen("search-recent")
    private static let recentLimit = 20

    private var surfaces: SurfaceCache { roster.connection.surfaces }

    private func receive(_ next: SearchState) {
        let needle = next.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else {
            state = next
            return
        }
        var recent = surfaces.remembered(Recent.self, Self.recentKey) ?? Recent()
        state = overlay(next, with: recent.states[needle])
        guard !next.sources.values.contains(where: { $0.phase == .loading }) else { return }
        recent.states[needle] = SearchState(query: next.query, sources: next.sources.filter { $0.value.phase == .loaded })
        recent.order.removeAll { $0 == needle }
        recent.order.append(needle)
        while recent.order.count > Self.recentLimit { recent.states[recent.order.removeFirst()] = nil }
        surfaces.remember(recent, Self.recentKey)
    }

    private func overlay(_ next: SearchState, with held: SearchState?) -> SearchState {
        guard let held else { return next }
        var merged = next
        for (source, current) in next.sources where current.phase == .loading && current.items.isEmpty {
            guard let previous = held.sources[source] else { continue }
            merged.sources[source] = SourceState(phase: .loading, items: previous.items, isIncomplete: previous.isIncomplete)
        }
        return merged
    }

    private func refresh() {
        requestSink.yield(Request(query: query, sources: Set(scope.sources).intersection(supported), bots: roster.searchBots))
    }
}
