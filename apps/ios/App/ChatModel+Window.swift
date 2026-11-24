import PalChat

extension ChatModel {
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
