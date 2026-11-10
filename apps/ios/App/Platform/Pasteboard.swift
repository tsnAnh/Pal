#if os(iOS)
import UIKit

enum Pasteboard {
    @MainActor
    static var string: String? {
        get { UIPasteboard.general.string }
        set { UIPasteboard.general.string = newValue }
    }
}
#elseif os(macOS)
import AppKit

enum Pasteboard {
    @MainActor
    static var string: String? {
        get { NSPasteboard.general.string(forType: .string) }
        set {
            NSPasteboard.general.clearContents()
            if let newValue { NSPasteboard.general.setString(newValue, forType: .string) }
        }
    }
}
#endif
