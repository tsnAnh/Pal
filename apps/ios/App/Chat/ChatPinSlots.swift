import Observation

@MainActor
@Observable
final class ChatPinSlot {
    fileprivate(set) var isPinned: Bool

    init(isPinned: Bool) {
        self.isPinned = isPinned
    }
}

@MainActor
final class ChatPinSlots {
    private var slots: [String: ChatPinSlot] = [:]
    private var pinned: String?

    func slot(for id: String) -> ChatPinSlot {
        if let existing = slots[id] { return existing }
        let slot = ChatPinSlot(isPinned: id == pinned)
        slots[id] = slot
        return slot
    }

    func pin(_ id: String?) {
        guard id != pinned else { return }
        if let pinned { slots[pinned]?.isPinned = false }
        pinned = id
        if let id { slot(for: id).isPinned = true }
    }

    func keep(_ ids: Set<String>) {
        for id in slots.keys where !ids.contains(id) && id != pinned { slots[id] = nil }
    }
}
