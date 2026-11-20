#if os(macOS)
import PalDesign
import SwiftUI

struct MacSheetFrame: ViewModifier {
    let readable: Bool

    @Environment(\.macWindowSize) private var windowSize
    @State private var dialogs = MacDialogCenter()

    func body(content: Content) -> some View {
        let size = MacModalSizing.sheetSize(window: windowSize?.size ?? .zero)
        content
            .frame(maxWidth: readable ? MacModalSizing.readableColumn : .infinity, maxHeight: .infinity)
            .frame(width: size.width, height: size.height)
            .environment(\.macDialogCenter, dialogs)
            .overlay { MacDialogLayer(center: dialogs, window: size) }
    }
}
#endif
