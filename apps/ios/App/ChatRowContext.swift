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

    var rowContextSource: ChatRowContextSource {
        let finding = isFinding
        return ChatRowContextSource(
            accent: chatAccent,
            findQuery: finding ? findQuery : "",
            findMatchIDs: finding ? findMatchIDs : [],
            currentFindRowID: currentFindRowID,
            reactions: reactions,
            answeringConnections: answeringConnections
        )
    }
}

struct ChatRowContextSource {
    let accent: BotAccent?
    let findQuery: String
    let findMatchIDs: Set<String>
    let currentFindRowID: String?
    let reactions: [String: String]
    let answeringConnections: Set<String>

    func context(for row: ChatRow) -> ChatRowContext {
        var answering: Set<String> = []
        if case .connection = row.kind { answering = answeringConnections }
        return ChatRowContext(
            accent: accent,
            findQuery: findMatchIDs.contains(row.id) ? findQuery : "",
            isCurrentMatch: currentFindRowID == row.id,
            reaction: reactions[row.id],
            answeringConnections: answering
        )
    }
}
