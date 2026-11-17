import PalDesign
import PalKanban
import PalTransport
import SwiftUI

struct KanbanBoardsView: View {
    let store: KanbanStore
    let open: (String) -> Void
    let close: (() -> Void)?

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        KanbanPage(title: KanbanPresentation.surfaceTitle, identifier: "kanbanBoards", back: nil, close: close) {
            content
        }
        .task(id: scenePhase == .active) {
            if scenePhase == .active { await store.loadBoards() }
        }
        .refreshable { await store.loadBoards() }
    }

    @ViewBuilder
    private var content: some View {
        let boards = store.session.boards
        if !boards.isEmpty {
            if store.boardsLoad == .failed || store.boardsLoad == .unreachable { failure }
            list(boards)
        } else {
            switch store.boardsLoad {
            case .idle, .loading:
                LoadingRow(title: "Loading boards", identifier: "kanbanBoardsLoading")
            case .failed, .unreachable:
                failure
            case .ready:
                ContentUnavailableView("No boards yet", systemImage: "rectangle.split.3x1", description: Text("Boards on this server appear here."))
            default:
                KanbanUnavailable(load: store.boardsLoad)
            }
        }
    }

    private var failure: some View {
        FailureCard(message: (store.boardsLoad == .unreachable ? KanbanLoad.unreachable : KanbanLoad.failed).message ?? "", identifier: "kanbanBoardsFailure") {
            Task { await store.loadBoards() }
        }
    }

    private func list(_ boards: [KanbanBoard]) -> some View {
        GroupedCard(accessibilityIdentifier: "kanbanBoardsList") {
            ForEach(boards) { board in
                SettingsRow.navigate(
                    board.name,
                    subtitle: subtitle(board),
                    value: total(board),
                    accessibilityIdentifier: "kanbanBoard-\(board.scope.board)"
                ) { open(board.scope.board) }
            }
        }
    }

    private func subtitle(_ board: KanbanBoard) -> String? {
        var parts: [String] = []
        if !board.description.isEmpty { parts.append(board.description) }
        if board.dispatchMode == "external" { parts.append("Coordinator-owned") }
        if board.archived { parts.append("Archived") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func total(_ board: KanbanBoard) -> String? {
        guard let counts = board.taskCounts else { return nil }
        let sum = counts.values.reduce(0, +)
        return sum == 1 ? "1 card" : "\(sum) cards"
    }
}

struct KanbanUnavailable: View {
    let load: KanbanLoad

    var body: some View {
        ContentUnavailableView(title, systemImage: symbol, description: Text(load.message ?? ""))
            .frame(maxWidth: .infinity, minHeight: 280)
            .accessibilityIdentifier("kanbanUnavailable")
    }

    private var title: String {
        switch load {
        case .unsupported: "Not available on this server"
        case .permissionDenied: "No access"
        case .boardAbsent: "Board not found"
        case .boardArchived: "Board archived"
        case .cardAbsent: "Card not found"
        default: "Unavailable"
        }
    }

    private var symbol: String {
        load == .unsupported ? "server.rack" : "rectangle.split.3x1"
    }
}
