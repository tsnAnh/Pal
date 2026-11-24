import PalChat

extension ChatModel {
    private func shownRange(of count: Int) -> Range<Int> {
        windowRange.upperBound == count ? windowRange : max(0, count - ChatRowWindow.size)..<count
    }

    var windowRows: [ChatRow] { Array(rows[shownRange(of: rows.count)]) }
    var windowRowIDs: [String] { Array(rowIDs[shownRange(of: rowIDs.count)]) }
    var hiddenOlder: Int { shownRange(of: rowIDs.count).lowerBound }

    var hasSession: Bool { snapshot?.sessionID != nil }
    var canLoadOlder: Bool { hiddenOlder > 0 || olderHistory.canLoad }
    var olderHistoryShown: OlderHistory { hiddenOlder > 0 ? .idle : olderHistory }

    func expandWindow() {
        if window.expand(rowIDs) { publishWindow() }
    }

    func showInWindow(_ rowID: String) {
        if window.reveal(rowID, in: rowIDs) { publishWindow() }
    }

    func trimWindow() {
        if window.trim(rowIDs) { publishWindow() }
    }
}
