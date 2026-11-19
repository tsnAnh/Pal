import PalChat
import PalDesign
import SwiftUI

extension ChatModel {
    func toggleUnread() {
        let current = bot
        if current.isUnread { roster.markRead(current.name) } else { roster.markUnread(current) }
    }
}

extension ChatRowView {
    typealias TablesProvider = @MainActor @Sendable () -> [MarkdownTable]

    func messageActions(for text: String, failedSubmission: String? = nil, tables: @escaping TablesProvider = { [] }) -> MessageActions {
        let id = row.id
        let model = model
        let canReact: @MainActor @Sendable () -> Bool = { model.canReact(to: id) }
        let react: @MainActor @Sendable (String) -> Void = { model.react(to: id, with: $0) }
        let reply: @MainActor @Sendable () -> Void = { model.beginReply(to: id) }
        let isChatUnread: @MainActor @Sendable () -> Bool = { model.bot.isUnread }
        let toggleUnread: @MainActor @Sendable () -> Void = { model.toggleUnread() }
        var retry: (@MainActor @Sendable () -> Void)?
        if let submission = failedSubmission {
            retry = { model.retry(submission) }
        }
        let ink: Color = BubblePalette.ink(accent: context.accent)
        return MessageActions(
            rowID: id,
            text: text,
            reaction: context.reaction,
            ink: ink,
            canReact: canReact,
            react: react,
            reply: reply,
            isChatUnread: isChatUnread,
            toggleUnread: toggleUnread,
            retry: retry,
            tables: tables
        )
    }

    func userActions(text: String, delivery: BubbleDelivery) -> MessageActions? {
        switch delivery {
        case .sent: messageActions(for: text)
        case .failed(let submission): messageActions(for: text, failedSubmission: submission)
        case .sending, .waitingForConnection: nil
        }
    }
}
