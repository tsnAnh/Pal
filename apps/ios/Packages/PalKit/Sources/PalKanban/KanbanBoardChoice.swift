public enum KanbanBoardChoice {
    public static let defaultBoard = "default"
    public static let maxSlugLength = 128

    public static func pick(boards: [String], last: String?) -> String? {
        if let last, boards.contains(last) { return last }
        if boards.count == 1 { return boards[0] }
        if boards.contains(defaultBoard) { return defaultBoard }
        return boards.first
    }

    public static func showsPicker(boards: [String]) -> Bool {
        boards.count > 1
    }
}
