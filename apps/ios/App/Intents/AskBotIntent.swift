import AppIntents
import Foundation
import HermesChat
import HermesDiagnostics

struct AskBotIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask a Bot"
    static let description = IntentDescription("Ask one of your bots a question and hear its answer.")
    static let replyDeadline = Duration.seconds(25)
    static let longRunningReplyDeadline = Duration.seconds(240)
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    @Parameter(title: "Bot")
    var bot: BotEntity

    @Parameter(title: "Question", requestValueDialog: "What do you want to ask?")
    var request: String

    @Dependency var environment: IntentEnvironment

    static var parameterSummary: some ParameterSummary {
        Summary("Ask \(\.$bot) \(\.$request)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let environment = environment
        let target = bot
        let question = request
        let report: ErrandReport
        if #available(iOS 27.0, macOS 27.0, *) {
            Diagnostics.osLog().info("intents", "ask runs as a long-running intent")
            report = try await performBackgroundTask { @Sendable in
                try await Self.ask(question, of: target, deadline: Self.longRunningReplyDeadline, in: environment)
            }
        } else {
            report = try await Self.ask(question, of: target, deadline: Self.replyDeadline, in: environment)
        }
        if report.offersChat, systemContext.currentMode.canContinueInForeground {
            try await continueInForeground(report.dialog)
            environment.open(target)
        }
        return .result(value: report.spoken, dialog: report.dialog)
    }

    @MainActor
    private static func ask(
        _ question: String,
        of bot: BotEntity,
        deadline: Duration,
        in environment: IntentEnvironment
    ) async throws -> ErrandReport {
        let outcome = try await environment.withErrand(for: bot) { errand in
            try await errand.ask(question, deadline: deadline)
        }
        return ErrandReport(outcome: outcome, botName: bot.name)
    }
}

@available(iOS 27.0, macOS 27.0, *)
extension AskBotIntent: LongRunningIntent {}
