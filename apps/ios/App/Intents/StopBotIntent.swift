import AppIntents
import Foundation
import PalChat

struct StopBotIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop a Bot"
    static let description = IntentDescription("Stop what one of your bots is working on right now.")

    @Parameter(title: "Bot")
    var bot: BotEntity

    @Dependency var environment: IntentEnvironment

    static var parameterSummary: some ParameterSummary {
        Summary("Stop \(\.$bot)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let name = bot.name
        let outcome = try await environment.withErrand(for: bot) { try await $0.stop() }
        let text = switch outcome {
        case .notRunning: String(localized: "\(name) isn't working on anything.")
        case .stopped: String(localized: "Stopped \(name).")
        case .stopping: String(localized: "Told \(name) to stop. It may take a moment.")
        }
        return .result(dialog: IntentDialog(LocalizedStringResource(stringLiteral: text)))
    }
}
