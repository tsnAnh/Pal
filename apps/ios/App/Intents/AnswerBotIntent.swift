import AppIntents
import Foundation
import PalChat
import PalDiagnostics

struct AnswerBotIntent: AppIntent {
    static let title: LocalizedStringResource = "Answer a Bot's Question"
    static let description = IntentDescription("Answer the question one of your bots is waiting on and hear what it does next.")
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    @Parameter(title: "Bot")
    var bot: BotEntity

    @Parameter(title: "Answer", requestValueDialog: "What is your answer?")
    var answer: String

    @Dependency var environment: IntentEnvironment

    static var parameterSummary: some ParameterSummary {
        Summary("Answer \(\.$bot) with \(\.$answer)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let environment = environment
        let target = bot
        let reply = answer
        let report: ErrandReport
        if #available(iOS 27.0, macOS 27.0, *) {
            Diagnostics.osLog().info("intents", "answer runs as a long-running intent")
            report = try await performBackgroundTask { @Sendable in
                try await Self.answer(reply, for: target, deadline: AskBotIntent.longRunningReplyDeadline, in: environment)
            }
        } else {
            report = try await Self.answer(reply, for: target, deadline: AskBotIntent.replyDeadline, in: environment)
        }
        if report.offersChat, systemContext.currentMode.canContinueInForeground {
            try await continueInForeground(report.dialog)
            environment.open(target)
        }
        return .result(value: report.spoken, dialog: report.dialog)
    }

    @MainActor
    private static func answer(
        _ text: String,
        for bot: BotEntity,
        deadline: Duration,
        in environment: IntentEnvironment
    ) async throws -> ErrandReport {
        let result = try await environment.withErrand(for: bot) { errand in
            try await errand.answer(text, deadline: deadline)
        }
        return ErrandReport(answer: result, botName: bot.name)
    }
}

@available(iOS 27.0, macOS 27.0, *)
extension AnswerBotIntent: LongRunningIntent {}
