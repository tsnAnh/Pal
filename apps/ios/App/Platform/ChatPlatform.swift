import PalDesign
import PalRoster
import SwiftUI

extension View {
    func chatColumn() -> some View {
        #if os(macOS)
        frame(maxWidth: MacMetrics.chatColumn + 2 * ChatMetrics.edgeMargin).frame(maxWidth: .infinity)
        #else
        frame(maxWidth: ChatMetrics.padColumn + 2 * ChatMetrics.edgeMargin).frame(maxWidth: .infinity)
        #endif
    }

    func macChatChrome(
        bot: BotRow,
        activity: BotActivity,
        mood: AvatarMood,
        router: AppRouter,
        find: @escaping () -> Void,
        focusComposer: @escaping () -> Void
    ) -> some View {
        #if os(macOS)
        safeAreaBar(edge: .top) {
            MacChatHeader(bot: bot, activity: activity, mood: mood, router: router)
        }
        .modifier(MacChatActions(find: find, focusComposer: focusComposer))
        #else
        self
        #endif
    }
}
