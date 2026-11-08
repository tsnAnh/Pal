import Foundation
import HermesChat
import HermesProtocol

enum VoicePhrase {
    static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Hermes Bots"
    }

    static func answer(_ bot: String) -> String { "Answer \(bot) in \(appName)" }
    static func approval(_ bot: String) -> String { "Review \(bot) approval in \(appName)" }
    static func status(_ bot: String) -> String { "What's \(bot) doing in \(appName)" }
    static func lastReply(_ bot: String) -> String { "What did \(bot) say in \(appName)" }
}

enum PromptWording {
    static func summary(of prompt: PendingPrompt, from bot: String) -> String {
        switch prompt.kind {
        case .clarify: question(prompt, from: bot)
        case .approval: approval(prompt, from: bot)
        }
    }

    static func invitation(for prompt: PendingPrompt, from bot: String) -> String {
        switch prompt.kind {
        case .clarify: String(localized: "Say “\(VoicePhrase.answer(bot))” to reply.")
        case .approval: String(localized: "Say “\(VoicePhrase.approval(bot))” to decide.")
        }
    }

    static func relay(_ prompt: PendingPrompt, from bot: String) -> String {
        "\(summary(of: prompt, from: bot)) \(invitation(for: prompt, from: bot))"
    }

    private static func question(_ prompt: PendingPrompt, from bot: String) -> String {
        guard let text = clean(prompt.question) else { return String(localized: "\(bot) has a question for you.") }
        let asked = String(localized: "\(bot) asks: \(text)")
        guard !prompt.choices.isEmpty else { return asked }
        let options = prompt.choices.joined(separator: ", ")
        return asked + " " + String(localized: "The options are \(options).")
    }

    private static func approval(_ prompt: PendingPrompt, from bot: String) -> String {
        if let command = prompt.shortCommand { return String(localized: "\(bot) wants to run a command: \(command)") }
        if let detail = clean(prompt.description) { return String(localized: "\(bot) needs your approval: \(detail)") }
        return String(localized: "\(bot) needs your approval.")
    }

    private static func clean(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
