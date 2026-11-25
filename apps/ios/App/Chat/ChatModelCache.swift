import PalRoster


@MainActor
final class ChatModelCache {
    func model(for bot: BotRow, links: BotLinks, roster: RosterModel) -> ChatModel {
        ChatModel(bot: bot, links: links, roster: roster)
    }
}
