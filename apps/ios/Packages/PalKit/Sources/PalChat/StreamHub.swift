import Foundation
import Synchronization

final class StreamHub<Element: Sendable>: Sendable {
    private struct State {
        var subscribers: [UUID: AsyncStream<Element>.Continuation] = [:]
        var recent: [Element] = []
        var finished = false
    }

    private let state = Mutex(State())
    private let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
    }

    func stream() -> AsyncStream<Element> {
        let (stream, continuation) = AsyncStream.makeStream(of: Element.self, bufferingPolicy: .bufferingNewest(capacity))
        let id = UUID()
        let finished = state.withLock { state -> Bool in
            for element in state.recent { continuation.yield(element) }
            if !state.finished { state.subscribers[id] = continuation }
            return state.finished
        }
        if finished {
            continuation.finish()
        } else {
            continuation.onTermination = { [weak self] _ in self?.state.withLock { $0.subscribers[id] = nil } }
        }
        return stream
    }

    func yield(_ element: Element) {
        let targets = state.withLock { state -> [AsyncStream<Element>.Continuation] in
            guard !state.finished else { return [] }
            state.recent.append(element)
            if state.recent.count > capacity { state.recent.removeFirst(state.recent.count - capacity) }
            return Array(state.subscribers.values)
        }
        for target in targets { target.yield(element) }
    }

    func finish() {
        let targets = state.withLock { state -> [AsyncStream<Element>.Continuation] in
            state.finished = true
            defer { state.subscribers = [:] }
            return Array(state.subscribers.values)
        }
        for target in targets { target.finish() }
    }
}
