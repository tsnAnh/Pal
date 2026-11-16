import PalDesign
import PalKanban
import PalTransport
import SwiftUI

enum KanbanRoute: Hashable {
    case board(String)
    case card(board: String, taskID: String)
}

private struct KanbanPollID: Hashable {
    let board: String?
    let isActive: Bool
}

extension KanbanStore {
    static func live(connection: ConnectionModel) -> KanbanStore {
        KanbanStore(service: KanbanService(gateway: KanbanGateway { method, params in try await connection.rpc(method, params) }))
    }
}

struct KanbanSurface: View {
    @State private var store: KanbanStore
    @State private var path: [KanbanRoute] = []
    let close: (() -> Void)?

    @Environment(\.scenePhase) private var scenePhase

    init(connection: ConnectionModel, close: (() -> Void)?) {
        _store = State(initialValue: KanbanStore.live(connection: connection))
        self.close = close
    }

    private var visibleBoard: String? {
        for route in path.reversed() {
            if case .board(let slug) = route { return slug }
        }
        return nil
    }

    var body: some View {
        let pollID = KanbanPollID(board: visibleBoard, isActive: scenePhase == .active)
        NavigationStack(path: $path) {
            KanbanBoardsView(store: store, open: { path.append(.board($0)) }, close: close)
                .environment(\.sheetChromeHostedInNavigation, true)
                .navigationDestination(for: KanbanRoute.self) { route in
                    destination(route)
                        .environment(\.sheetChromeHostedInNavigation, true)
                }
        }
        .tint(.primary)
        .task(id: pollID) {
            guard pollID.isActive, let board = pollID.board else { return }
            await store.poll(board: board)
        }
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
    private let content: Content

    init(title: String, identifier: String, back: (() -> Void)?, close: (() -> Void)?, @ViewBuilder content: () -> Content) {
        self.title = title
        self.identifier = identifier
        self.back = back
        self.close = close
        self.content = content()
    }

    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            macHeader
            scrolling
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

    private var scrolling: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PalMetrics.cardGap) { content }
                .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
    }

    #if os(macOS)
    private var macHeader: some View {
        HStack {
            if let back {
                Button(action: back) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                        Text(title).font(.system(size: 15, weight: .medium)).lineLimit(1)
                    }
                    .foregroundStyle(PalTokens.textPrimary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("\(identifier)-back")
            } else {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(PalTokens.textPrimary)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer()
        }
        .padding(.leading, 29)
        .padding(.trailing, 38)
        .padding(.top, 47)
        .padding(.bottom, 16)
    }
    #endif
}

enum KanbanTime {
    static func text(_ seconds: Int?) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds)).formatted(date: .abbreviated, time: .shortened)
    }
}
