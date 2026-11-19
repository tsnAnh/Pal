import PalChat
import PalDesign

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
        return MessageActions(
            rowID: id,
            text: text,
            reaction: context.reaction,
            ink: BubblePalette.ink(accent: context.accent),
            canReact: { model.canReact(to: id) },
            react: { model.react(to: id, with: $0) },
            reply: { model.beginReply(to: id) },
            isChatUnread: { model.bot.isUnread },
            toggleUnread: { model.toggleUnread() },
            retry: failedSubmission.map { submission in { model.retry(submission) } },
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
