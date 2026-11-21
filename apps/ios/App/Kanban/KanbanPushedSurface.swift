import PalDesign
import PalKanban
import PalTransport
import SwiftUI

struct KanbanPushedSurface: View {
    @State private var store: KanbanStore
    @State private var selected: String?
    @State private var card: KanbanRoute?
    let roster: RosterModel
    let back: () -> Void

    @Environment(\.scenePhase) private var scenePhase

    init(connection: ConnectionModel, roster: RosterModel, back: @escaping () -> Void) {
        _store = State(initialValue: KanbanStore.live(connection: connection)) // perf-lint: ok three reference fields, no I/O; same as KanbanSurface
        self.roster = roster
        self.back = back
    }

    var body: some View {
        let target = KanbanFollowTarget(board: selected, isActive: scenePhase == .active)
        let kanbanRoster = roster.kanbanRoster
        KanbanBoardsView(store: store, selected: $selected, close: nil, back: back) { card = .card(board: $0, taskID: $1) }
            .environment(\.sheetChromeHostedInNavigation, true)
            .environment(\.kanbanRoster, kanbanRoster)
            .navigationDestination(item: $card) { route in
                KanbanPushedCard(store: store, route: route, roster: kanbanRoster)
            }
            .tint(.primary)
            .task(id: target) {
                guard let board = target.followedBoard else { return }
                await store.poll(board: board)
            }
    }
}

struct KanbanPushedCard: View {
    let store: KanbanStore
    let route: KanbanRoute
    let roster: KanbanRoster

    @State private var next: KanbanRoute?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        switch route {
        case .card(let board, let taskID):
            KanbanCardView(store: store, board: board, taskID: taskID, openCard: { next = .card(board: board, taskID: $0) }, back: { dismiss() })
                .environment(\.sheetChromeHostedInNavigation, true)
                .environment(\.kanbanRoster, roster)
                .navigationDestination(item: $next) { KanbanPushedCard(store: store, route: $0, roster: roster) }
        }
    }
}
