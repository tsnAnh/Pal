import PalDesign
import SwiftUI

struct MacModalEnvironment: ViewModifier {
    #if os(macOS)
    @State private var windowSize = MacWindowSize()
    @State private var dialogs = MacDialogCenter()
    #endif

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .environment(\.macWindowSize, windowSize)
            .environment(\.macDialogCenter, dialogs)
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
