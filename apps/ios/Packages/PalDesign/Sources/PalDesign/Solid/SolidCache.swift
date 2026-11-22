import Synchronization

final class SolidCache<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    struct Statistics: Equatable, Sendable {
        var hits = 0
        var misses = 0
    }

    private struct Entry {
        let value: Value
        let weight: Int
        var stamp: UInt64
    }

    private struct State {
        var entries: [Key: Entry] = [:]
        var weight = 0
        var clock: UInt64 = 0
        var statistics = Statistics()
    }

    private let state = Mutex(State())
    private let capacity: Int
    private let weightLimit: Int

    init(capacity: Int, weightLimit: Int = .max) {
        self.capacity = capacity
        self.weightLimit = weightLimit
    }

    var statistics: Statistics { state.withLock { $0.statistics } }
    var count: Int { state.withLock { $0.entries.count } }

    func value(for key: Key, weight: Int = 1, build: () -> Value) -> Value {
        if let known = state.withLock({ state -> Value? in
            guard var entry = state.entries[key] else { return nil }
            state.clock += 1
            entry.stamp = state.clock
            state.entries[key] = entry
            state.statistics.hits += 1
            return entry.value
        }) { return known }
        let built = build()
        state.withLock { state in
            state.statistics.misses += 1
            state.clock += 1
            if let replaced = state.entries.updateValue(Entry(value: built, weight: weight, stamp: state.clock), forKey: key) {
                state.weight -= replaced.weight
            }
            state.weight += weight
            while state.entries.count > 1, state.entries.count > capacity || state.weight > weightLimit {
                guard let oldest = state.entries.min(by: { $0.value.stamp < $1.value.stamp }) else { break }
                state.entries.removeValue(forKey: oldest.key)
                state.weight -= oldest.value.weight
            }
        }
        return built
    }
}
