import PalRoster

@MainActor
final class ChatModelCache {
    static let capacity = 6
    static let rowBudget = 3_000

    private var models: [String: ChatModel] = [:]
    private var recency: [String] = []
    private var account: String?

    func model(for bot: BotRow, links: BotLinks, roster: RosterModel) -> ChatModel {
        let current = roster.connection.accountKey
        if account != current {
            models.removeAll()
            recency.removeAll()
            account = current
        }
        if let cached = models[bot.name] {
            guard !cached.isActive else { return ChatModel(bot: bot, links: links, roster: roster) }
            touch(bot.name)
            return cached
        }
        let model = ChatModel(bot: bot, links: links, roster: roster)
        models[bot.name] = model
        recency.append(bot.name)
        evict()
        return model
    }

    private func touch(_ name: String) {
        recency.removeAll { $0 == name }
        recency.append(name)
    }

    private func evict() {
        func over() -> Bool {
            recency.count > Self.capacity || models.values.reduce(0) { $0 + $1.rows.count } > Self.rowBudget
        }
        for name in recency.dropLast() where over() {
            guard let model = models[name], !model.isActive else { continue }
            models[name] = nil
            recency.removeAll { $0 == name }
        }
    }
}
