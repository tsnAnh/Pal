import AppIntents
import Foundation
import PalChat

enum ApprovalVerdict: String, AppEnum {
    case approved
    case denied
    case nothingWaiting

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Approval Verdict"
    static let caseDisplayRepresentations: [ApprovalVerdict: DisplayRepresentation] = [
        .approved: "Approved",
        .denied: "Denied",
        .nothingWaiting: "Nothing waiting",
    ]
}

enum ApprovalChoice: String, AppEnum {
    case approve
    case deny

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Decision"
    static let caseDisplayRepresentations: [ApprovalChoice: DisplayRepresentation] = [
        .approve: DisplayRepresentation(title: "Approve", synonyms: ["Allow", "Accept"]),
        .deny: DisplayRepresentation(title: "Deny", synonyms: ["Reject", "Decline"]),
    ]

    var decision: ApprovalDecision {
        switch self {
        case .approve: .approve
        case .deny: .deny
        }
    }
}

struct ReviewApprovalIntent: AppIntent {
    static let title: LocalizedStringResource = "Review a Bot's Request"
    static let description = IntentDescription("Approve or deny something one of your bots is asking permission to do.")

    @Parameter(title: "Bot")
    var bot: BotEntity

    @Parameter(title: "Decision", default: .approve)
    var choice: ApprovalChoice

    @Dependency var environment: IntentEnvironment

    init() {}

    init(choice: ApprovalChoice) {
        self.choice = choice
    }

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$choice) the request from \(\.$bot)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<ApprovalVerdict> & ProvidesDialog {
        let name = bot.name
        let decision = choice.decision
        let verdict = try await environment.withErrand(for: bot) { errand in
            guard let prompt = try await errand.pendingApproval() else { return ApprovalVerdict.nothingWaiting }
            if decision == .approve { try await self.confirm(PromptWording.summary(of: prompt, from: name)) }
            try await errand.decide(decision, on: prompt)
            return decision == .approve ? .approved : .denied
        }
        return .result(value: verdict, dialog: Self.dialog(verdict, botName: name))
    }

    @MainActor
    private func confirm(_ summary: String) async throws {
        try await requestConfirmation(
            actionName: .custom(
                acceptLabel: "Approve",
                acceptAlternatives: ["Yes", "Allow", "Go ahead"],
                denyLabel: "Not now",
                denyAlternatives: ["No", "Cancel"],
                destructive: false
            ),
            dialog: IntentDialog(LocalizedStringResource(stringLiteral: summary))
        )
    }

    private static func dialog(_ verdict: ApprovalVerdict, botName: String) -> IntentDialog {
        let text = switch verdict {
        case .approved: String(localized: "Approved. \(botName) is carrying on.")
        case .denied: String(localized: "Denied. \(botName) won't do it.")
        case .nothingWaiting: String(localized: "\(botName) isn't waiting on a request.")
        }
        return IntentDialog(LocalizedStringResource(stringLiteral: text))
    }
}
