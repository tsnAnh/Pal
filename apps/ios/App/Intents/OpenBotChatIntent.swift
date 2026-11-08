import AppIntents

struct OpenBotChatIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open a Bot's Chat"
    static let description = IntentDescription("Open the chat with one of your bots.")

    @Parameter(title: "Bot")
    var target: BotEntity

    @Dependency var environment: IntentEnvironment

    @MainActor
    func perform() async throws -> some IntentResult {
        environment.open(target)
        return .result()
    }
}
