import AuthenticationServices

#if os(iOS)
import UIKit

@MainActor
enum PresentationAnchor {
    static func current() -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let active = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        if let window = active?.keyWindow ?? active?.windows.first { return window }
        return ASPresentationAnchor(windowScene: active!)
    }
}
#elseif os(macOS)
import AppKit

@MainActor
enum PresentationAnchor {
    static func current() -> ASPresentationAnchor {
        NSApplication.shared.keyWindow
            ?? NSApplication.shared.mainWindow
            ?? NSApplication.shared.windows.first { $0.isVisible }
            ?? NSWindow()
    }
}
#endif
