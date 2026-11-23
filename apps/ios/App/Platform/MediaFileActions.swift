import Foundation
import PalChat
#if os(macOS)
import AppKit
#endif

@MainActor
enum MediaFileActions {
    #if os(macOS)
    @discardableResult
    static func saveAs(_ file: URL, suggestedName: String) -> Bool {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = MediaDownloads.safeFileName(suggestedName)
        guard panel.runModal() == .OK, let destination = panel.url else { return false }
        do {
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.copyItem(at: file, to: destination)
            return true
        } catch {
            let alert = NSAlert()
            alert.messageText = String(localized: "The file couldn't be saved.")
            alert.runModal()
            return false
        }
    }

    static func reveal(_ file: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }
    #endif

    static func revealing(_ file: URL) {
        #if os(macOS)
        reveal(file)
        #endif
    }

    static func deliver(_ file: URL, name: String) {
        #if os(macOS)
        saveAs(file, suggestedName: name)
        MediaDownloads.remove(file)
        #else
        SharePresenter.present(items: [file]) { MediaDownloads.remove(file) }
        #endif
    }
}
