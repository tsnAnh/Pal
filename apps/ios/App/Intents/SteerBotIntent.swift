import AppIntents
import Foundation
import PalChat

struct SteerBotIntent: AppIntent {
    static let title: LocalizedStringResource = "Steer a Bot"
    static let description = IntentDescription("Give one of your bots guidance while it works. If it is idle, the guidance goes out as a new task.")

    @Parameter(title: "Bot")
    var bot: BotEntity

    @Parameter(title: "Guidance", requestValueDialog: "What should the bot do differently?")
    var guidance: String

    @Dependency var environment: IntentEnvironment

    static var parameterSummary: some ParameterSummary {
        Summary("Steer \(\.$bot) with \(\.$guidance)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let name = bot.name
        let text = guidance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw $guidance.needsValueError("What should \(name) do differently?") }
        let outcome = try await environment.withErrand(for: bot) { try await $0.steer(text) }
        let spoken = switch outcome {
        case .steered: String(localized: "Passed that to \(name). It will pick it up as it works.")
        case .startedNewTask: String(localized: "\(name) wasn't working on anything, so I sent that as a new task.")
        }
        return .result(dialog: IntentDialog(LocalizedStringResource(stringLiteral: spoken)))
    }
}
