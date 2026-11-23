#if os(macOS)
import AppKit

enum PalAlert {
    @MainActor
    static func notice(_ title: String, message: String? = nil) {
        let alert = NSAlert()
        alert.messageText = title
        if let message { alert.informativeText = message }
        alert.addButton(withTitle: String(localized: "OK"))
        alert.runModal()
    }
}
#endif
