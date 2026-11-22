import PalDesign
import PalRoster
import SwiftUI

enum ChatLoading {
    static let delay = Duration.milliseconds(300)
}

extension View {
    func newestFirst() -> some View {
        scaleEffect(x: 1, y: -1, anchor: .center)
    }

    func chatListRow() -> some View {
        padding(.horizontal, ChatMetrics.edgeMargin).chatColumn()
    }

    func chatColumn() -> some View {
        #if os(macOS)
        frame(maxWidth: MacLayoutMetrics.chatColumnMax + 2 * ChatMetrics.edgeMargin).frame(maxWidth: .infinity)
        #else
        frame(maxWidth: ChatMetrics.padColumn + 2 * ChatMetrics.edgeMargin).frame(maxWidth: .infinity)
        #endif
    }

    func macChatChrome(
        model: ChatModel,
        router: AppRouter,
        find: @escaping () -> Void,
        focusComposer: @escaping () -> Void
    ) -> some View {
        #if os(macOS)
        safeAreaBar(edge: .top) {
            ChatMacHeaderHost(model: model)
        }
        .modifier(MacChatActions(find: find, focusComposer: focusComposer))
        #else
        self
        #endif
    }
}
