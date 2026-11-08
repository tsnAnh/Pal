import Foundation
import HermesDiagnostics

public actor SearchCoordinator {
    public nonisolated let states: AsyncStream<SearchState>

    private let continuation: AsyncStream<SearchState>.Continuation
    private let engine: SearchEngine
    private let debounce: Duration
    private let diagnostics: Diagnostics
    private var generation = 0
    private var running: Task<Void, Never>?
    private var state = SearchState()

    public init(engine: SearchEngine, debounce: Duration = .milliseconds(250), diagnostics: Diagnostics = .silent) {
        (states, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(32))
        self.engine = engine
        self.debounce = debounce
        self.diagnostics = diagnostics
    }

    public func update(query: String, sources: Set<SearchScope>, bots: [SearchBot]) {
        generation += 1
        running?.cancel()
        let current = generation
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var next = SearchState(query: query)
        var remote: [SearchScope] = []
        for source in SearchScope.allCases where sources.contains(source) && source != .all {
            if source == .bots {
                next.sources[source] = SourceState(phase: .loaded, items: SearchEngine.botItems(needle, bots))
            } else if source == .messages, needle.isEmpty {
                next.sources[source] = SourceState(phase: .loaded)
            } else {
                next.sources[source] = SourceState(phase: .loading)
                remote.append(source)
            }
        }
        state = next
        continuation.yield(next)
        guard !remote.isEmpty else {
            running = nil
            return
        }
        let wait = needle.isEmpty ? Duration.zero : debounce
        running = Task { [engine] in
            if wait > .zero {
                do { try await Task.sleep(for: wait) } catch { return }
            }
            await withTaskGroup(of: Void.self) { group in
                for source in remote {
                    group.addTask {
                        do {
                            let result = try await engine.run(source, query: needle, bots: bots)
                            await self.publish(source, result, generation: current)
                        } catch is CancellationError {
                            return
                        } catch {
                            await self.publish(source, SourceState(phase: .failed), generation: current, error: error)
                        }
                    }
                }
            }
        }
    }

    public func stop() {
        generation += 1
        running?.cancel()
        running = nil
        continuation.finish()
    }

    private func publish(_ source: SearchScope, _ result: SourceState, generation published: Int, error: (any Error)? = nil) {
        guard published == generation else { return }
        if let error { diagnostics.info("search", "\(source.rawValue) source failed: \(Diagnostics.describe(error))") }
        state.sources[source] = result
        continuation.yield(state)
    }
}
