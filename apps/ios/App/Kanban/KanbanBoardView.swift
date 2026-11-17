import PalDesign
import PalKanban
import PalTransport
import SwiftUI

struct KanbanBoardView: View {
    let store: KanbanStore
    let board: String
    let openCard: (String) -> Void
    let back: () -> Void

    @State private var filter = KanbanFilter()
    @State private var pagerColumn: KanbanColumn = .backlog
    @State private var selected: String?
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    private var cache: KanbanBoardCache? { store.session.cache(board) }
    private var load: KanbanLoad { store.load(of: board) }

    private var showsColumns: Bool {
        #if os(macOS)
        return true
        #else
        return sizeClass == .regular
        #endif
    }

    var body: some View {
        KanbanPage(title: cache?.board?.name ?? board, identifier: "kanbanBoard", back: back, close: nil, scrolls: cache == nil) {
            content
        }
        .refreshable { await store.refreshSnapshot(board: board) }
        .task(id: cache?.generation) { await store.prefetchDetails(board: board) }
    }

    @ViewBuilder
    private var content: some View {
        if cache != nil {
            loaded
        } else {
            switch load {
            case .idle, .loading, .ready:
                LoadingRow(title: String(localized: "Loading cards"), identifier: "kanbanBoardLoading")
            case .failed, .unreachable:
                failure
            default:
                KanbanUnavailable(load: load)
            }
        }
    }

    private var failure: some View {
        FailureCard(message: (load == .unreachable ? KanbanLoad.unreachable : KanbanLoad.failed).message ?? "", identifier: "kanbanBoardFailure") {
            Task { await store.refreshSnapshot(board: board) }
        }
    }

    private var loaded: some View {
        let rows = KanbanBoardLayout.rows(session: store.session, board: board)
        let layout = KanbanBoardLayout(rows: rows, filter: filter)
        return VStack(spacing: 0) {
            notice
            if rows.isEmpty {
                ContentUnavailableView("No cards yet", systemImage: "rectangle.split.3x1", description: Text("Cards on this board appear here."))
                    .accessibilityIdentifier("kanbanBoardEmpty")
            } else {
                KanbanFilterBar(filter: $filter, layout: layout, boardName: cache?.board?.name ?? board, compact: !showsColumns)
                if layout.matchingCards == 0 {
                    noMatches
                } else {
                    columns(layout)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var notice: some View {
        if load == .unreachable || load == .failed, let message = load.message {
            HStack(spacing: 8) {
                Image(systemName: "wifi.exclamationmark")
                Text(message).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .hermesText(.rowSubtitle)
            .foregroundStyle(PalTokens.textSecondary)
            .padding(.horizontal, PalMetrics.screenMargin)
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("kanbanBoardNotice")
        }
    }

    private var noMatches: some View {
        ContentUnavailableView {
            Label("No matching cards", systemImage: "line.3.horizontal.decrease.circle")
        } description: {
            Text("Try a different search or clear the filters.")
        } actions: {
            Button("Clear filters") { filter = KanbanFilter() }
        }
        .accessibilityIdentifier("kanbanNoMatches")
    }

    @ViewBuilder
    private func columns(_ layout: KanbanBoardLayout) -> some View {
        if showsColumns {
            wide(layout)
        } else {
            #if os(iOS)
            pager(layout)
            #endif
        }
    }

    private func select(_ taskID: String) {
        if showsColumns { selected = taskID } else { openCard(taskID) }
    }

    private func wide(_ layout: KanbanBoardLayout) -> some View {
        HStack(spacing: 0) {
            GeometryReader { proxy in
                let inset = PalMetrics.screenMargin
                let gaps = CGFloat(max(layout.columns.count - 1, 0)) * 10
                let fit = (proxy.size.width - inset * 2 - gaps) / CGFloat(max(layout.columns.count, 1))
                ScrollView(.horizontal) {
                    GlassEffectContainer(spacing: 10) {
                        HStack(alignment: .top, spacing: 10) {
                            ForEach(layout.columns) { column in
                                KanbanColumnView(layout: column, selected: selected, width: max(fit, 220), open: select)
                            }
                        }
                    }
                    .padding(.horizontal, inset)
                    .padding(.bottom, 12)
                    .frame(height: proxy.size.height)
                }
                .scrollIndicators(.hidden)
            }
            if let selected {
                Divider()
                KanbanCardView(
                    store: store, board: board, taskID: selected, mode: .pane,
                    openCard: { self.selected = $0 }, back: { self.selected = nil }
                )
                .frame(width: 360)
            }
        }
    }

    #if os(iOS)
    private func pager(_ layout: KanbanBoardLayout) -> some View {
        let current = Binding<KanbanColumn>(
            get: { layout.columns.contains { $0.column == pagerColumn } ? pagerColumn : .backlog },
            set: { pagerColumn = $0 }
        )
        return VStack(spacing: 8) {
            FilterChipBar(
                items: layout.columns.map { FilterChipItem(id: $0.column, title: "\($0.column.title) \($0.rows.count)") },
                selection: current,
                accessibilityIdentifier: "kanbanColumns"
            )
            TabView(selection: current) {
                ForEach(layout.columns) { column in
                    KanbanColumnView(layout: column, selected: nil, width: nil, open: select)
                        .padding(.horizontal, PalMetrics.screenMargin)
                        .padding(.bottom, 8)
                        .tag(column.column)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
    }
    #endif
}
