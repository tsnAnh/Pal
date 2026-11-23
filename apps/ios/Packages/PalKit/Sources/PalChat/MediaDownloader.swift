import Foundation

public enum MediaTransferError: Error, Sendable, Equatable {
    case tooLarge(size: Int)
    case truncated
    case unwritable
}

public struct MediaTransferProgress: Sendable, Equatable {
    public let received: Int
    public let total: Int?

    public init(received: Int, total: Int?) {
        self.received = received
        self.total = total
    }

    public var fraction: Double? {
        guard let total, total > 0 else { return nil }
        return min(1, Double(received) / Double(total))
    }
}

public enum MediaDownloads {
    public static var directory: URL {
        FileManager.default.temporaryDirectory.appending(path: "pal-media", directoryHint: .isDirectory)
    }

    public static let staleAfter: TimeInterval = 24 * 60 * 60

    public static func sweepStale(in root: URL = directory, now: Date = Date()) {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, now.timeIntervalSince(modified) > staleAfter { try? manager.removeItem(at: entry) }
        }
    }

    public static func remove(_ file: URL) {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    public static func safeFileName(_ proposed: String) -> String {
        let last = (proposed as NSString).lastPathComponent
        let cleaned = String(String.UnicodeScalarView(last.unicodeScalars.filter { $0.value >= 0x20 && $0 != ":" && $0 != "/" && $0 != "\\" }))
        let trimmed = cleaned.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed == "." || trimmed == ".." ? "media" : trimmed
    }

    public static func download(
        _ reference: MediaReference,
        from source: any MediaAssetSource,
        limit: Int?,
        root: URL = directory,
        chunkBytes: Int = MediaLimits.chunkBytes,
        progress: @Sendable (MediaTransferProgress) -> Void = { _ in }
    ) async throws -> URL {
        let folder = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let file = folder.appending(path: safeFileName(reference.name), directoryHint: .notDirectory)
        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        guard manager.createFile(atPath: file.path, contents: nil) else {
            try? manager.removeItem(at: folder)
            throw MediaTransferError.unwritable
        }
        do {
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            var offset = 0
            var reachedEnd = false
            while !reachedEnd {
                try Task.checkCancellation()
                let chunk = try await source.chunk(reference, offset: offset, length: chunkBytes)
                if let limit, chunk.total > limit { throw MediaTransferError.tooLarge(size: chunk.total) }
                if chunk.data.isEmpty, offset < chunk.total { throw MediaTransferError.truncated }
                try handle.write(contentsOf: chunk.data)
                offset += chunk.data.count
                progress(MediaTransferProgress(received: offset, total: chunk.total))
                reachedEnd = offset >= chunk.total
            }
            return file
        } catch {
            try? manager.removeItem(at: folder)
            throw error
        }
    }
}
