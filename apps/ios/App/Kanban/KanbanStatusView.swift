import PalKanban
import PalTransport
import SwiftUI

extension ChatStatusCopy {
    static func boardsFailure(_ load: KanbanLoad, code: String?) -> ChatStatusCopy {
        let unverified = code == "boards_unverified"
        return ChatStatusCopy(
            symbol: load == .unreachable ? "wifi.slash" : "exclamationmark.triangle",
            title: String(localized: "Can't load boards"),
            reason: unverified
                ? String(localized: "Your computer sent no boards and Pal can't confirm there are none. Try again.")
                : load.message ?? String(localized: "Your computer couldn't answer. Try again."),
            code: code ?? "unknown"
        )
    }

    static func unreadableBoard(_ board: KanbanBoard) -> ChatStatusCopy {
        ChatStatusCopy(
            symbol: "exclamationmark.triangle",
            title: board.name,
            reason: String(localized: "This board is on your computer, but Pal can't read it right now. Try again in a moment."),
            code: "board_\(board.unavailable ?? "unreadable")"
        )
    }
}

struct KanbanStatusView: View {
    let copy: ChatStatusCopy
    let retry: () -> Void

    var body: some View {
        ChatInstallStatus(copy: copy, primaryTitle: String(localized: "Try Again"), isBusy: false, perform: retry, secondary: { EmptyView() })
    }
}
