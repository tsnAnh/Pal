import Foundation
import PalChat
import PalProtocol

struct ConversationCache: Sendable {
    let store: CacheStore
    let account: String

    func load(bot: String) -> CachedTranscript? {
        store.load(CachedTranscript.self, name: CachedTranscript.cacheName(forBot: bot), account: account)
    }

    func save(_ transcript: CachedTranscript, bot: String) {
        store.save(transcript, name: CachedTranscript.cacheName(forBot: bot), account: account)
    }

    func remove(bot: String) {
        store.remove(name: CachedTranscript.cacheName(forBot: bot), account: account)
    }
}

struct LastOpenedBot: Codable, Sendable {
    static let cacheName = "last-opened-bot"

    var name: String
}

extension RosterModel {
    var conversationCache: ConversationCache {
        ConversationCache(store: connection.cache, account: connection.accountKey)
    }

    func rememberOpened(bot name: String) {
        connection.cache.save(LastOpenedBot(name: name), name: LastOpenedBot.cacheName, account: connection.accountKey)
    }

    var lastOpenedBot: String? {
        connection.cache.load(LastOpenedBot.self, name: LastOpenedBot.cacheName, account: connection.accountKey)?.name
    }
}

extension RosterModel {
    var primaryBot: BotRow? {
        if let primary = bots.first(where: \.isPrimary) { return primary.isHidden ? nil : primary }
        return visibleBots.first
    }

    var launchBot: BotRow? {
        if let name = lastOpenedBot, let remembered = bot(named: name), !remembered.isHidden { return remembered }
        return primaryBot ?? visibleBots.first ?? bots.first
    }
}

extension AppRouter {
    var currentBotName: String? {
        if case .chat(let name)? = path.first { name } else { nil }
    }
}
