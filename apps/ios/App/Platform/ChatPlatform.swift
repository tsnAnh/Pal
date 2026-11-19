import PalDesign
import PalRoster
import SwiftUI

enum ChatEdgeFade {
    static let feather: CGFloat = 24
    static let loadingDelay = Duration.milliseconds(300)
    static var topFloor: CGFloat {
        #if os(macOS)
        MacMetrics.topBarHeight
        #else
        0
        #endif
    }
}

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
            MacChatHeader(bot: bot, activity: activity, mood: mood)
        }
        .modifier(MacChatActions(find: find, focusComposer: focusComposer))
        #else
        self
        #endif
    }
}
