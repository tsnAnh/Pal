public extension KanbanStore {
    func visibleRows(board: String) -> [KanbanCardRow]? {
        KanbanReadiness.rows(session: session, board: board, settledGeneration: settledGenerations[board])
    }
}
