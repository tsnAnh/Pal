import CoreGraphics
import Foundation

#if os(iOS)
import UIKit

enum ImageActions {
    @MainActor
    static func copy(_ image: CGImage) {
        UIPasteboard.general.image = UIImage(cgImage: image)
    }
}
#elseif os(macOS)
import AppKit
import UniformTypeIdentifiers

enum ImageActions {
    @MainActor
    static func copy(_ image: CGImage) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([NSImage(cgImage: image)])
    }

    @MainActor
    static func save(_ image: CGImage, suggestedName: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = ((suggestedName as NSString).deletingPathExtension as String) + ".png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = NSImage(cgImage: image).pngData() else {
            NSAlert.show(String(localized: "The image couldn't be saved."))
            return
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            NSAlert.show(String(localized: "The image couldn't be saved."))
        }
    }
}

private extension NSAlert {
    @MainActor
    static func show(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
    }
}
#endif
