#if os(iOS)
import PalAuth
import UIKit

enum Pasteboard {
    @MainActor
    static var string: String? {
        get { UIPasteboard.general.string }
        set { UIPasteboard.general.string = newValue }
    }
}

struct SystemPasteboard: PasteboardAccess {
    var changeCount: Int { UIPasteboard.general.changeCount }

    func clear() {
        UIPasteboard.general.items = []
    }
}
#elseif os(macOS)
import AppKit
import PalAuth

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

struct SystemPasteboard: PasteboardAccess {
    var changeCount: Int { NSPasteboard.general.changeCount }

    func clear() {
        NSPasteboard.general.clearContents()
    }
}
#endif
