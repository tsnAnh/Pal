#if os(macOS)
import PalDesign
import SwiftUI

struct MacSheetFrame: ViewModifier {
    let size: MacModalSize

    @Environment(\.macWindowSize) private var windowSize
    @State private var dialogs = MacDialogCenter()

    func body(content: Content) -> some View {
        let frame = size.frame(in: windowSize?.size ?? .zero)
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .macModalFrame(frame)
            .environment(\.macDialogCenter, dialogs)
            .environment(\.macEscapeStack, nil)
            .overlay { MacDialogLayer(center: dialogs, window: frame.size) }
    }
}
#endif
