import AppIntents
import Foundation
import PalChat

struct LastReplyIntent: AppIntent {
    static let title: LocalizedStringResource = "Hear a Bot's Last Reply"
    static let description = IntentDescription("Hear the last thing one of your bots said in its chat.")

    @Parameter(title: "Bot")
    var bot: BotEntity

    @Dependency var environment: IntentEnvironment

    static var parameterSummary: some ParameterSummary {
        Summary("Read the last reply from \(\.$bot)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let name = bot.name
        let reply = try await environment.withErrand(for: bot) { try await $0.lastReply() }
        guard let reply else {
            return .result(value: "", dialog: Self.dialog(String(localized: "\(name) hasn't replied yet.")))
        }
        return .result(value: reply.text, dialog: Self.dialog(Self.spoken(reply, botName: name)))
    }

    static func spoken(_ reply: LastReply, botName: String) -> String {
        let excerpt = SpokenExcerpt(reply.text)
        var parts: [String] = []
        if reply.botIsWorkingOnMore { parts.append(String(localized: "\(botName) is working on something new. Their last reply was:")) }
        parts.append(excerpt.text)
        if excerpt.isTruncated { parts.append(String(localized: "The rest is in the chat.")) }
        return parts.joined(separator: " ")
    }

    private static func dialog(_ text: String) -> IntentDialog {
        IntentDialog(LocalizedStringResource(stringLiteral: text))
    }
}
