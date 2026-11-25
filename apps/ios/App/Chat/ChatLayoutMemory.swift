@MainActor
final class ChatLayoutMemory {
    let planner = ChatTailPlanner()
    let rowHeights = ChatRowHeights()
}

extension ChatScrollController {
    var planner: ChatTailPlanner { layout.planner }
    var rowHeights: ChatRowHeights { layout.rowHeights }
}
