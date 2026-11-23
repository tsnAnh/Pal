import Foundation
import PalChat
import PalDiagnostics
import PalProtocol

struct ConversationCache: Sendable {
    let store: CacheStore
    let account: String

    func load(bot: String) -> CachedTimeline? {
        store.load(CachedTimeline.self, name: CachedTimeline.cacheName(forBot: bot), account: account)
    }

    func save(_ timeline: CachedTimeline, bot: String) {
        store.save(timeline, name: CachedTimeline.cacheName(forBot: bot), account: account)
    }

    func remove(bot: String) {
        store.remove(name: CachedTimeline.cacheName(forBot: bot), account: account)
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
        PalPerf.mainDiskRead { connection.cache.load(LastOpenedBot.self, name: LastOpenedBot.cacheName, account: connection.accountKey)?.name }
    }
}

extension RosterModel {
    func stageIntro(_ intro: BotIntro, for name: String) {
        pendingIntros[name] = intro
    }

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
