import HermesDesign
import SwiftUI

extension View {
    func chatColumn() -> some View {
        #if os(macOS)
        frame(maxWidth: MacMetrics.chatColumn + 2 * ChatMetrics.edgeMargin).frame(maxWidth: .infinity)
        #else
        frame(maxWidth: ChatMetrics.padColumn + 2 * ChatMetrics.edgeMargin).frame(maxWidth: .infinity)
        #endif
    }

    func macChatActions(find: @escaping () -> Void, focusComposer: @escaping () -> Void) -> some View {
        #if os(macOS)
        modifier(MacChatActions(find: find, focusComposer: focusComposer))
        #else
        self
        #endif
    }
}
