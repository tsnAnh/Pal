import PalDesign
import PalKanban
import PalTransport
import SwiftUI

enum KanbanRoute: Hashable {
    case board(String)
    case card(board: String, taskID: String)
}

extension KanbanStore {
    static func live(connection: ConnectionModel) -> KanbanStore {
        KanbanStore(
            service: KanbanService(gateway: KanbanGateway { method, params in try await connection.rpc(method, params) }),
            disk: KanbanDiskCache(store: connection.cache, account: connection.accountKey)
        )
    }
}

struct KanbanSurface: View {
    @State private var store: KanbanStore
    @State private var path: [KanbanRoute] = []
    let roster: RosterModel
    let close: (() -> Void)?

    @Environment(\.scenePhase) private var scenePhase

    init(connection: ConnectionModel, roster: RosterModel, close: (() -> Void)?) {
        _store = State(initialValue: KanbanStore.live(connection: connection))
        self.roster = roster
        self.close = close
    }

    private var visibleBoard: String? {
        for route in path.reversed() {
            if case .board(let slug) = route { return slug }
        }
        return nil
    }

    var body: some View {
        let target = KanbanFollowTarget(board: visibleBoard, isActive: scenePhase == .active)
        NavigationStack(path: $path) {
            KanbanBoardsView(store: store, open: { path.append(.board($0)) }, close: close)
                .environment(\.sheetChromeHostedInNavigation, true)
                .navigationDestination(for: KanbanRoute.self) { route in
                    destination(route)
                        .environment(\.sheetChromeHostedInNavigation, true)
                }
        }
        .tint(.primary)
        .environment(\.kanbanRoster, kanbanRoster)
        .task(id: target) {
            guard let board = target.followedBoard else { return }
            await store.poll(board: board)
        }
    }

    private var kanbanRoster: KanbanRoster {
        KanbanRoster(
            names: KanbanBots(displayNames: Dictionary(roster.bots.map { ($0.name, $0.displayName) }, uniquingKeysWith: { first, _ in first })),
            specs: Dictionary(roster.bots.map { ($0.name, $0.spec) }, uniquingKeysWith: { first, _ in first })
        )
    }

    @ViewBuilder
    private func destination(_ route: KanbanRoute) -> some View {
        switch route {
        case .board(let slug):
            KanbanBoardView(store: store, board: slug, openCard: { path.append(.card(board: slug, taskID: $0)) }, back: pop)
        case .card(let board, let taskID):
            KanbanCardView(store: store, board: board, taskID: taskID, openCard: { path.append(.card(board: board, taskID: $0)) }, back: pop)
        }
    }

    private func pop() {
        if !path.isEmpty { path.removeLast() }
    }
}

struct KanbanPage<Content: View>: View {
    let title: String
    let identifier: String
    let back: (() -> Void)?
    let close: (() -> Void)?
    let scrolls: Bool
    private let content: Content

    init(title: String, identifier: String, back: (() -> Void)?, close: (() -> Void)?, scrolls: Bool = true, @ViewBuilder content: () -> Content) {
        self.title = title
        self.identifier = identifier
        self.back = back
        self.close = close
        self.scrolls = scrolls
        self.content = content()
    }

    var body: some View {
        #if os(macOS)
        scrolling
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .navigationTitle(title)
            .toolbar {
                if back == nil, let close {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(role: .close, action: close)
                            .accessibilityIdentifier("\(identifier)-close")
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(identifier)
        #else
        SheetChrome(
            title: title,
            leading: back == nil ? .close : .back,
            accessibilityIdentifier: identifier,
            onLeading: { (back ?? close)?() }
        ) {
            scrolling
        }
        #endif
    }

    @ViewBuilder
    private var scrolling: some View {
        if scrolls {
            ScrollView {
                VStack(alignment: .leading, spacing: PalMetrics.cardGap) { content }
                    .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
        } else {
            content
        }
    }

}

enum KanbanTime {
    static func text(_ seconds: Int?) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds)).formatted(date: .abbreviated, time: .shortened)
    }
}
