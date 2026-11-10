import AppIntents
import Foundation
import HermesRoster

enum BotStatus: String, AppEnum {
    case idle
    case working
    case needsInput
    case offline
    case needsSetup

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Bot Status"
    static let caseDisplayRepresentations: [BotStatus: DisplayRepresentation] = [
        .idle: "Idle",
        .working: "Working",
        .needsInput: "Needs your input",
        .offline: "Offline",
        .needsSetup: "Needs setup",
    ]

    init(_ activity: BotActivity) {
        self = switch activity {
        case .idle: .idle
        case .working: .working
        case .needsInput: .needsInput
        case .offline: .offline
        case .attention: .needsSetup
        }
    }

    func spoken(botName: String) -> String {
        switch self {
        case .idle: String(localized: "\(botName) isn't working on anything right now.")
        case .working: String(localized: "\(botName) is working on something.")
        case .needsInput:
            String(localized: "\(botName) is waiting for you. Say “\(VoicePhrase.answer(botName))” to reply to a question, or “\(VoicePhrase.approval(botName))” to decide on a request.")
        case .offline: String(localized: "Pal can't reach \(botName) right now.")
        case .needsSetup: String(localized: "\(botName) hasn't finished setting up. Open the chat to continue.")
        }
    }
}

struct BotStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Check on a Bot"
    static let description = IntentDescription("Find out whether one of your bots is working, idle, or waiting for you.")

    @Parameter(title: "Bot")
    var bot: BotEntity

    @Dependency var environment: IntentEnvironment

    static var parameterSummary: some ParameterSummary {
        Summary("Check on \(\.$bot)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<BotStatus> & ProvidesDialog {
        let status = BotStatus(try await environment.activity(of: bot))
        return .result(value: status, dialog: IntentDialog(LocalizedStringResource(stringLiteral: status.spoken(botName: bot.name))))
    }
}
