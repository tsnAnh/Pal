import Foundation

#if os(macOS)
import AppKit
#endif

enum FileSaveError: Error {
    case noDestination
}

@MainActor
enum FileSaver {
    static func safeName(_ proposed: String) -> String {
        let last = (proposed as NSString).lastPathComponent
        let cleaned = last.unicodeScalars.filter { $0.value >= 0x20 && $0 != ":" && $0 != "/" && $0 != "\\" }
        let name = String(String.UnicodeScalarView(cleaned)).trimmingCharacters(in: .whitespaces)
        return name.isEmpty || name == "." || name == ".." ? "file" : name
    }

    static func uniqueURL(in directory: URL, name: String, exists: (URL) -> Bool) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = directory.appending(path: name, directoryHint: .notDirectory)
        var number = 2
        while exists(candidate) {
            let numbered = ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
            candidate = directory.appending(path: numbered, directoryHint: .notDirectory)
            number += 1
        }
        return candidate
    }

    #if os(macOS)
    static func save(_ data: Data, name: String) throws -> String {
        guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            throw FileSaveError.noDestination
        }
        let url = uniqueURL(in: downloads, name: safeName(name)) { FileManager.default.fileExists(atPath: $0.path) }
        try data.write(to: url, options: .withoutOverwriting)
        NSWorkspace.shared.activateFileViewerSelecting([url])
        return String(localized: "Saved to Downloads")
    }
    #else
    static func save(_ data: Data, name: String) throws -> String {
        let directory = FileManager.default.temporaryDirectory.appending(path: "chat-file-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: safeName(name), directoryHint: .notDirectory)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        SharePresenter.present(items: [url]) {
            try? FileManager.default.removeItem(at: directory)
        }
        return ""
    }
    #endif
}
