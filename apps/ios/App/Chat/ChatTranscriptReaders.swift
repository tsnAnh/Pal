import PalChat
import SwiftUI

struct ChatRowsSync: ViewModifier {
    let model: ChatModel
    let scroll: ChatScrollController

    func body(content: Content) -> some View {
        content.onChange(of: model.windowRowIDs, initial: true) { _, ids in
            scroll.rowsChanged(ids)
            if scroll.isPinnedToBottom { model.trimWindow() }
        }
    }
}

struct ChatOlderPaging: ViewModifier {
    let model: ChatModel
    let scroll: ChatScrollController

    private struct Demand: Hashable {
        let wants: Bool
        let state: OlderHistory
    }

    private static let interval = Duration.milliseconds(250)

    func body(content: Content) -> some View {
        content.task(id: Demand(wants: scroll.wantsOlder, state: model.olderHistoryShown)) {
            guard scroll.wantsOlder, model.canLoadOlder else { return }
            while !Task.isCancelled {
                model.wantOlder()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }
}

struct ChatScreenAccessibility: ViewModifier {
    let model: ChatModel

    private var summary: String {
        let count = String(localized: "\(model.rows.count) messages")
        return model.olderHistory == .loading ? count + ", " + String(localized: "loading earlier messages") : count
    }

    func body(content: Content) -> some View {
        content
            .accessibilityIdentifier("chatScreen")
            .accessibilityValue(Text(summary))
    }
}

struct ChatFindReveal: ViewModifier {
    let model: ChatModel
    let scroll: ChatScrollController

    func body(content: Content) -> some View {
        content.onChange(of: model.currentFindRowID) { _, id in
            guard let id else { return }
            model.showInWindow(id)
            scroll.reveal(id)
        }
    }
}
