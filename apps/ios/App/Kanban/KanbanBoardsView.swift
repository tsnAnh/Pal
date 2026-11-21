import PalDesign
import PalKanban
import PalTransport
import SwiftUI

struct KanbanBoardsView: View {
    let store: KanbanStore
    @Binding var selected: String?
    let close: (() -> Void)?
    var back: (() -> Void)?
    let openCard: (String, String) -> Void

    @State private var last: String?
    @State private var lastLoaded = false
    @Environment(\.scenePhase) private var scenePhase

    private var boards: [KanbanBoard] { store.session.boards }
    private var slugs: [String] { boards.map(\.scope.board) }

    var body: some View {
        Group {
            if let board = selected, let unreadable = boards.first(where: { $0.scope.board == board && $0.unavailable != nil }) {
                KanbanPage(
                    title: KanbanPresentation.surfaceTitle, identifier: "kanbanBoardUnavailable", back: back, close: close, scrolls: false,
                    picker: KanbanBoardPicker(boards: boards, selected: $selected)
                ) {
                    KanbanStatusView(copy: .unreadableBoard(unreadable)) { Task { await store.loadBoards() } }
                }
            } else if let board = selected {
                KanbanBoardView(
                    store: store, board: board, openCard: { openCard(board, $0) }, close: close, back: back,
                    picker: KanbanBoardChoice.showsPicker(boards: slugs) ? KanbanBoardPicker(boards: boards, selected: $selected) : nil
                )
                .id(board)
            } else {
                KanbanPage(title: KanbanPresentation.surfaceTitle, identifier: "kanbanBoards", back: back, close: close, scrolls: false) {
                    content
                }
            }
        }
        .task(id: scenePhase == .active) {
            if !lastLoaded {
                last = await store.lastBoard()
                lastLoaded = true
            }
            if scenePhase == .active { await store.loadBoards() }
        }
        .onChange(of: slugs, initial: true) { choose() }
        .onChange(of: lastLoaded) { choose() }
        .onChange(of: store.boardsLoad) { choose() }
        .onChange(of: selected) { _, board in
            if let board, slugs.contains(board) { store.remember(board: board) }
        }
    }

    private func choose() {
        guard lastLoaded else { return }
        if slugs.isEmpty {
            selected = store.boardsLoad == .ready ? nil : (selected ?? last)
        } else if selected.map({ !slugs.contains($0) }) ?? true {
            selected = KanbanBoardChoice.pick(boards: slugs, last: last)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.boardsLoad {
        case .idle, .loading:
            KanbanBoardSkeleton(wide: KanbanBoardsView.wide)
        case .failed, .unreachable:
            KanbanStatusView(copy: .boardsFailure(store.boardsLoad, code: store.boardsCode)) {
                Task { await store.loadBoards() }
            }
        case .ready:
            ContentUnavailableView {
                Label("No boards yet", palIcon: "rectangle.split.3x1")
            } description: {
                Text("Boards on this server appear here.")
            }
        default:
            KanbanUnavailable(load: store.boardsLoad)
        }
    }

    private static var wide: Bool {
        #if os(macOS)
        true
        #else
        UIDevice.current.userInterfaceIdiom == .pad
        #endif
    }
}

struct KanbanBoardPicker: View {
    let boards: [KanbanBoard]
    @Binding var selected: String?

    private var current: String { boards.first { $0.scope.board == selected }?.name ?? "" }

    var body: some View {
        Menu {
            Picker("Board", selection: $selected) {
                ForEach(boards) { board in
                    VStack {
                        Text(board.name)
                        if let detail = Self.detail(board) { Text(detail) }
                    }
                    .tag(Optional(board.scope.board))
                    .accessibilityIdentifier("kanbanBoard-\(board.scope.board)")
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 4) {
                Text(current).lineLimit(1)
                PalIcon("chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .hermesText(.chip)
            .foregroundStyle(PalTokens.textPrimary)
            #if os(macOS)
            .padding(.horizontal, 12)
            .frame(height: PalMetrics.sheetCloseControlSize)
            .palGlass(Capsule(), interactive: false)
            .contentShape(Capsule())
            #endif
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(Text("Board"))
        .accessibilityValue(Text(current))
        .accessibilityIdentifier("kanbanBoardPicker")
    }

    static func detail(_ board: KanbanBoard) -> String? {
        var parts: [String] = []
        if !board.description.isEmpty { parts.append(board.description) }
        if board.dispatchMode == "external" { parts.append("Coordinator-owned") }
        if board.archived { parts.append("Archived") }
        if board.unavailable != nil { parts.append("Can't be read") }
        if let counts = board.taskCounts {
            let sum = counts.values.reduce(0, +)
            parts.append(sum == 1 ? "1 card" : "\(sum) cards")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

struct KanbanUnavailable: View {
    let load: KanbanLoad

    var body: some View {
        ContentUnavailableView {
            Label(title, palIcon: symbol)
        } description: {
            Text(load.message ?? "")
        }
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
