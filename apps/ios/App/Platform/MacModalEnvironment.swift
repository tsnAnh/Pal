import PalDesign
import SwiftUI

struct MacModalEnvironment: ViewModifier {
    #if os(macOS)
    @State private var windowSize = MacWindowSize()
    @State private var dialogs = MacDialogCenter()
    @State private var sheets = MacSheetCenter()
    #endif

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .serviceSignInDialogHost()
            .environment(\.macWindowSize, windowSize)
            .environment(\.macDialogCenter, dialogs)
            .environment(\.macSheetCenter, sheets)
        #else
        content
        #endif
    }
}

extension View {
    func macModalEnvironment() -> some View {
        modifier(MacModalEnvironment())
    }
}
