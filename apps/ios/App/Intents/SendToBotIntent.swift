import AppIntents
import Foundation
import UniformTypeIdentifiers

struct SendToBotIntent: AppIntent {
    static let title: LocalizedStringResource = "Send to a Bot"
    static let description = IntentDescription("Send files, photos or documents to one of your bots, with an optional note.")

    @Parameter(
        title: "Files",
        supportedContentTypes: [.image, .pdf, .text, .data],
        inputConnectionBehavior: .connectToPreviousIntentResult
    )
    var files: [IntentFile]

    @Parameter(title: "Bot")
    var bot: BotEntity

    @Parameter(title: "Note")
    var note: String?

    @Dependency var environment: IntentEnvironment

    static var parameterSummary: some ParameterSummary {
        Summary("Send \(\.$files) to \(\.$bot)") {
            \.$note
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let name = bot.name
        let text = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !files.isEmpty || !text.isEmpty else { throw BotIntentError.nothingToSend }
        let outgoing = try IntentAttachments.files(from: files)
        _ = try await environment.tell(text, files: outgoing, to: bot)
        let spoken = switch outgoing.count {
        case 0: String(localized: "Sent to \(name).")
        case 1: String(localized: "Sent the file to \(name).")
        default: String(localized: "Sent \(outgoing.count) files to \(name).")
        }
        return .result(dialog: IntentDialog(LocalizedStringResource(stringLiteral: spoken)))
    }
}
