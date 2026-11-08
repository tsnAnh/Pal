import AppIntents
import Foundation

struct TellBotIntent: AppIntent {
    static let title: LocalizedStringResource = "Tell a Bot to Do Something"
    static let description = IntentDescription("Hand a task to one of your bots. It works on it in the background.")

    @Parameter(title: "Bot")
    var bot: BotEntity

    @Parameter(title: "Task", requestValueDialog: "What should the bot do?")
    var request: String

    @Dependency var environment: IntentEnvironment

    static var parameterSummary: some ParameterSummary {
        Summary("Tell \(\.$bot) to \(\.$request)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let task = request
        let name = bot.name
        _ = try await environment.tell(task, to: bot)
        return .result(dialog: IntentDialog(LocalizedStringResource(stringLiteral: String(localized: "Sent to \(name)."))))
    }
}
