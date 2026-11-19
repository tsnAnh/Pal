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

struct ChatEdgeFadeMask: View {
    var body: some View {
        GeometryReader { proxy in
            let insets = proxy.safeAreaInsets
            VStack(spacing: 0) {
                Color.clear
                    .frame(height: max(0, max(insets.top, ChatEdgeFade.topFloor) - ChatEdgeFade.feather / 2))
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: ChatEdgeFade.feather * 1.5)
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: ChatEdgeFade.feather)
                Color.clear
                    .frame(height: max(0, insets.bottom - ChatEdgeFade.feather))
            }
            .frame(width: proxy.size.width, height: proxy.size.height + insets.top + insets.bottom)
            .offset(y: -insets.top)
        }
    }
}

extension View {
    func newestFirst() -> some View {
        scaleEffect(x: 1, y: -1, anchor: .center)
    }

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
