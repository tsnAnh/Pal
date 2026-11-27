import PalChat

@MainActor
final class ChatSnapshotMemory {
    static let capacity = 12

    private var recent: [(bot: String, snapshot: TimelineSnapshot)] = []

    func snapshot(for bot: String) -> TimelineSnapshot? {
        recent.first { $0.bot == bot }?.snapshot
    }

    func remember(_ snapshot: TimelineSnapshot, for bot: String) {
        guard !snapshot.rows.isEmpty else { return }
        recent.removeAll { $0.bot == bot }
        recent.append((bot, snapshot))
        if recent.count > Self.capacity { recent.removeFirst(recent.count - Self.capacity) }
    }
}
