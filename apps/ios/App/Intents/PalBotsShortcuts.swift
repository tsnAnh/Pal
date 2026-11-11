import AppIntents

struct PalBotsShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskBotIntent(),
            phrases: [
                "Ask \(\.$bot) in \(.applicationName)",
                "Ask \(\.$bot) a question in \(.applicationName)",
            ],
            shortTitle: "Ask a Bot",
            systemImageName: "bubble.left.and.text.bubble.right"
        )
        AppShortcut(
            intent: TellBotIntent(),
            phrases: [
                "Tell \(\.$bot) in \(.applicationName)",
                "Give \(\.$bot) a task in \(.applicationName)",
            ],
            shortTitle: "Tell a Bot",
            systemImageName: "paperplane"
        )
        AppShortcut(
            intent: OpenBotChatIntent(),
            phrases: [
                "Open \(\.$target) in \(.applicationName)",
                "Open chat with \(\.$target) in \(.applicationName)",
            ],
            shortTitle: "Open a Chat",
            systemImageName: "bubble.left"
        )
        AppShortcut(
            intent: BotStatusIntent(),
            phrases: [
                "What's \(\.$bot) doing in \(.applicationName)",
                "Is \(\.$bot) done in \(.applicationName)",
            ],
            shortTitle: "Check on a Bot",
            systemImageName: "waveform.path.ecg"
        )
        AppShortcut(
            intent: LastReplyIntent(),
            phrases: [
                "What did \(\.$bot) say in \(.applicationName)",
                "Read the last reply from \(\.$bot) in \(.applicationName)",
            ],
            shortTitle: "Last Reply",
            systemImageName: "text.bubble"
        )
        AppShortcut(
            intent: AnswerBotIntent(),
            phrases: [
                "Answer \(\.$bot) in \(.applicationName)",
                "Reply to \(\.$bot) in \(.applicationName)",
            ],
            shortTitle: "Answer a Bot",
            systemImageName: "arrowshape.turn.up.left"
        )
        AppShortcut(
            intent: ReviewApprovalIntent(),
            phrases: [
                "Review \(\.$bot) approval in \(.applicationName)",
                "Review approval for \(\.$bot) in \(.applicationName)",
            ],
            shortTitle: "Review a Request",
            systemImageName: "checkmark.shield"
        )
        AppShortcut(
            intent: ReviewApprovalIntent(choice: .deny),
            phrases: [
                "Deny \(\.$bot) request in \(.applicationName)",
                "Deny the request from \(\.$bot) in \(.applicationName)",
            ],
            shortTitle: "Deny a Request",
            systemImageName: "xmark.shield"
        )
        AppShortcut(
            intent: StopBotIntent(),
            phrases: [
                "Stop \(\.$bot) in \(.applicationName)",
                "Tell \(\.$bot) to stop in \(.applicationName)",
            ],
            shortTitle: "Stop a Bot",
            systemImageName: "stop.circle"
        )
        AppShortcut(
            intent: SteerBotIntent(),
            phrases: [
                "Steer \(\.$bot) in \(.applicationName)",
                "Give \(\.$bot) guidance in \(.applicationName)",
            ],
            shortTitle: "Steer a Bot",
            systemImageName: "arrow.triangle.turn.up.right.diamond"
        )
    }
}
