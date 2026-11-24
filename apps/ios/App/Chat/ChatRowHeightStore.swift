import PalChat
import PalProtocol

@MainActor
final class ChatRowHeightStore {
    private let cache: CacheStore
    private let account: () -> String
    private var recent: [(bot: String, file: ChatRowHeightFile)] = []

    init(cache: CacheStore, account: @escaping () -> String) {
        self.cache = cache
        self.account = account
    }

    func remembered(for bot: String) -> ChatRowHeightFile? {
        recent.first { $0.bot == bot }?.file
    }

    func load(for bot: String) async -> ChatRowHeightFile? {
        if let file = remembered(for: bot) { return file }
        let cache = self.cache
        let account = account()
        let file = await cache.loadDetached(ChatRowHeightFile.self, name: ChatRowHeightFile.cacheName(forBot: bot), account: account)
        guard let file, remembered(for: bot) == nil else { return remembered(for: bot) }
        keep(file, for: bot)
        return file
    }

    func save(_ file: ChatRowHeightFile, for bot: String) {
        guard !file.rows.isEmpty, remembered(for: bot) != file else { return }
        keep(file, for: bot)
        cache.save(file, name: ChatRowHeightFile.cacheName(forBot: bot), account: account())
    }

    private func keep(_ file: ChatRowHeightFile, for bot: String) {
        recent.removeAll { $0.bot == bot }
        recent.append((bot, file))
        if recent.count > ChatSnapshotMemory.capacity { recent.removeFirst(recent.count - ChatSnapshotMemory.capacity) }
    }
}
