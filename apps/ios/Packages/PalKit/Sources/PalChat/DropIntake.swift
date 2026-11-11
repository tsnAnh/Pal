import Foundation
import UniformTypeIdentifiers

public enum DropIntake {
    public static let maximumPerDrop = 8

    public enum Item: Equatable, Sendable {
        case image(URL)
        case document(URL)
        case rejected(URL, reason: String)
    }

    public static func classify(_ urls: [URL], limit: Int = maximumPerDrop) -> [Item] {
        urls.enumerated().map { index, url in
            if index >= limit { return .rejected(url, reason: "Attach up to \(limit) files at a time.") }
            guard url.isFileURL else { return .rejected(url, reason: "Only files from this Mac can be attached.") }
            if isFolder(url) { return .rejected(url, reason: "Folders can't be attached.") }
            let type = UTType(filenameExtension: url.pathExtension)
            return type?.conforms(to: .image) == true ? .image(url) : .document(url)
        }
    }

    public static func rejectionMessage(for items: [Item]) -> String? {
        let reasons = items.compactMap { item -> String? in
            if case .rejected(_, let reason) = item { reason } else { nil }
        }
        guard let first = reasons.first else { return nil }
        return reasons.count == 1 ? first : "\(reasons.count) items weren't attached. \(first)"
    }

    private static func isFolder(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true || url.hasDirectoryPath
    }
}
