import PalDesign
import PalKanban
import PalTransport
import SwiftUI

struct KanbanBoardView: View {
    let store: KanbanStore
    let board: String
    let openCard: (String) -> Void
    let back: () -> Void

    private var cache: KanbanBoardCache? { store.session.cache(board) }
    private var load: KanbanLoad { store.load(of: board) }

    var body: some View {
        KanbanPage(title: cache?.board?.name ?? board, identifier: "kanbanBoard", back: back, close: nil) {
            content
        }
        .refreshable { await store.refreshSnapshot(board: board) }
    }

    @ViewBuilder
    private var content: some View {
        if let cache {
            if load == .failed { failure }
            cards(cache)
        } else {
            switch load {
            case .idle, .loading, .ready:
                LoadingRow(title: "Loading cards", identifier: "kanbanBoardLoading")
            case .failed:
                failure
            default:
                KanbanUnavailable(load: load)
            }
        }
    }

    private var failure: some View {
        FailureCard(message: KanbanLoad.failed.message ?? "", identifier: "kanbanBoardFailure") {
            Task { await store.refreshSnapshot(board: board) }
        }
    }

    @ViewBuilder
    private func cards(_ cache: KanbanBoardCache) -> some View {
        let groups = KanbanPresentation.groups(cards: cache.sortedCards, board: cache.board)
        if groups.isEmpty {
            ContentUnavailableView("No cards yet", systemImage: "rectangle.split.3x1", description: Text("Cards on this board appear here."))
        } else {
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: PalMetrics.captionToCardGap) {
                    SectionCaption("\(group.title) · \(group.count)", accessibilityIdentifier: "kanbanGroup-\(group.id)")
                    GroupedCard(accessibilityIdentifier: "kanbanGroupCards-\(group.id)") {
                        ForEach(group.cards) { card in
                            SettingsRow.navigate(
                                card.title,
                                subtitle: subtitle(card),
                                accessibilityIdentifier: "kanbanCard-\(card.taskID)"
                            ) { openCard(card.taskID) }
                        }
                    }
                }
            }
        }
    }

    private func subtitle(_ card: KanbanCard) -> String? {
        var parts: [String] = []
        if let assignee = card.assignee, !assignee.isEmpty { parts.append(assignee) }
        if let kind = card.blockKind, !kind.isEmpty { parts.append(kind) }
        if card.governed { parts.append("Outcome contract") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
