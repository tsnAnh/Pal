import Foundation
import PalChat
import PalDiagnostics
import PalProtocol

struct ConversationTimelineStore: TimelineStore {
    let bot: String
    let resolve: @Sendable @MainActor () -> (store: CacheStore, account: String)

    func load() async -> CachedTimeline? {
        let target = await resolve()
        return await target.store.loadDetached(CachedTimeline.self, name: CachedTimeline.cacheName(forBot: bot), account: target.account)
    }

    func save(_ timeline: CachedTimeline) {
        Task { @MainActor in
            let target = resolve()
            target.store.save(timeline, name: CachedTimeline.cacheName(forBot: bot), account: target.account)
        }
    }
}

struct LastOpenedBot: Codable, Sendable {
    static let cacheName = "last-opened-bot"

    var name: String
}

extension RosterModel {
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
