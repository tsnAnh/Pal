import PalDesign
import SwiftUI

struct MacModalEnvironment: ViewModifier {
    #if os(macOS)
    @State private var windowSize = MacWindowSize()
    @State private var escape = MacEscapeStack()
    @State private var sheets = MacSheetCenter()
    #endif

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .serviceSignInDialogHost()
            .environment(\.macWindowSize, windowSize)
            .environment(\.macDialogCenter, escape.dialogs)
            .environment(\.macSheetCenter, sheets)
            .palEscapeRoot(escape)
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
