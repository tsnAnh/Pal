#if os(iOS)
import UIKit

enum Haptics {
    @MainActor
    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    @MainActor
    static func impact() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    @MainActor
    static func light() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}
#elseif os(macOS)
import AppKit

enum Haptics {
    @MainActor
    static func selection() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
    }
}
#endif
