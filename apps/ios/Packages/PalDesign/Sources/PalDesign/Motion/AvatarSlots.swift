import Foundation
import Observation

struct AvatarSlotQueue: Equatable, Sendable {
    let capacity: Int
    private var waiting: [UUID] = []

    init(capacity: Int) {
        self.capacity = capacity
    }

    var holders: Set<UUID> { Set(waiting.prefix(capacity)) }

    func contains(_ id: UUID) -> Bool { waiting.contains(id) }

    mutating func request(_ id: UUID) {
        if !waiting.contains(id) { waiting.append(id) }
    }

    mutating func release(_ id: UUID) {
        waiting.removeAll { $0 == id }
    }
}

@MainActor
@Observable
final class AvatarSlotBudget {
    static let shared = AvatarSlotBudget(capacity: 1)

    private(set) var holders: Set<UUID> = []
    @ObservationIgnored private var queue: AvatarSlotQueue

    init(capacity: Int) {
        queue = AvatarSlotQueue(capacity: capacity)
    }

    func holds(_ id: UUID) -> Bool { holders.contains(id) }

    func request(_ id: UUID) {
        queue.request(id)
        publish()
    }

    func release(_ id: UUID) {
        guard queue.contains(id) else { return }
        queue.release(id)
        publish()
    }

    private func publish() {
        let next = queue.holders
        if next != holders { holders = next }
    }
}
