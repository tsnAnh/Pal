import PalDesign

struct ChatRowContext: Equatable {
    let accent: BotAccent?
    let findQuery: String
    let isCurrentMatch: Bool
    let reaction: String?
    let answeringConnections: Set<String>
}

extension ChatModel {
    var isOffline: Bool { connection != .live }
    var chatAccent: BotAccent? { bot.usesPrimaryLook ? nil : bot.accent }

    func rowContext(for row: ChatRow, accent: BotAccent?) -> ChatRowContext {
        var answering: Set<String> = []
        if case .connection = row.kind { answering = answeringConnections }
        return ChatRowContext(
            accent: accent,
            findQuery: isFinding && findMatchIDs.contains(row.id) ? findQuery : "",
            isCurrentMatch: currentFindRowID == row.id,
            reaction: reactions[row.id],
            answeringConnections: answering
        )
    }
}
