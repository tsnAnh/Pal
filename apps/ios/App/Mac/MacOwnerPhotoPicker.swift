#if os(macOS)
import AppKit
import CoreGraphics
import PalSettings
import UniformTypeIdentifiers

@MainActor
enum MacOwnerPhotoPicker {
    static func chooseImage() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = String(localized: "Choose a photo of you")
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func loadImage(_ url: URL) async -> CGImage? {
        await Task.detached(priority: .userInitiated) { try? OwnerPhotoImage.decode(contentsOf: url) }.value
    }
}
#endif
