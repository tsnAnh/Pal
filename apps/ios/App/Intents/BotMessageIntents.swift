import AppIntents
import Foundation
import GeoToolbox

@available(iOS 27.0, macOS 27.0, *)
@AppIntent(schema: .messages.sendMessage)
struct SendBotMessageIntent {
    var content: AttributedString?
    var destination: BotMessageDestination
    var subject: AttributedString?
    var attachments: [IntentFile]
    var audioMessage: IntentFile?
    var locations: [PlaceDescriptor]
    var links: [URL]
    var scheduledDate: Date?

    @Dependency var environment: IntentEnvironment

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[BotSentMessage]> & ProvidesDialog {
        let message = try BotMessageContent(
            content: content,
            subject: subject,
            attachments: attachments,
            audioMessage: audioMessage,
            locations: locations,
            links: links,
            scheduledDate: scheduledDate
        )
        let bot = try destination.bot()
        guard !message.text.isEmpty || !message.files.isEmpty else {
            throw $content.needsValueError("What should \(bot.name) do?")
        }
        let mark = try await environment.tell(message.text, files: message.files, to: bot)
        let sent = BotSentMessage(submissionID: mark.submissionID, text: message.text, to: bot, at: Date(), attachments: attachments)
        return .result(
            value: [sent],
            dialog: IntentDialog(LocalizedStringResource(stringLiteral: String(localized: "Sent to \(bot.name)."))
            )
        )
    }
}

@available(iOS 27.0, macOS 27.0, *)
@AppIntent(schema: .messages.draftMessage)
struct DraftBotMessageIntent {
    var destination: BotMessageDestination?
    var subject: AttributedString?
    var content: AttributedString?
    var attachments: [IntentFile]
    var audioMessage: IntentFile?
    var locations: [PlaceDescriptor]
    var links: [URL]
    var scheduledDate: Date?

    @Dependency var environment: IntentEnvironment

    @MainActor
    func perform() async throws -> some IntentResult {
        let message = try BotMessageContent(
            content: content,
            subject: subject,
            attachments: attachments,
            audioMessage: audioMessage,
            locations: locations,
            links: links,
            scheduledDate: scheduledDate,
            allowsFiles: false
        )
        guard let destination else { return .result() }
        let bot = try destination.bot()
        environment.draft(message.text, for: bot)
        return .result()
    }
}
