import Foundation

public struct MediaPosterKey: Sendable, Hashable {
    public let id: String
    public let pixels: Int

    public init(id: String, pixels: Int) {
        self.id = id
        self.pixels = pixels
    }

    var stem: String {
        let safe = id.unicodeScalars.map { scalar -> Character in
            switch scalar {
            case "a"..."z", "A"..."Z", "0"..."9", "-", "_": Character(scalar)
            default: "_"
            }
        }
        return "\(String(safe))-\(pixels)"
    }
}

public final class MediaPosterCache: @unchecked Sendable {
    private final class Entry {
        let preview: MediaPreview

        init(_ preview: MediaPreview) { self.preview = preview }
    }

    private struct Sidecar: Codable {
        var duration: TimeInterval?
        var size: Int?
        var width: Int?
        var height: Int?
        var hasPoster: Bool
    }

    public static let shared = MediaPosterCache()

    private let memory = NSCache<NSString, Entry>()
    private let directory: URL

    public init(directory: URL = MediaPosterCache.defaultDirectory) {
        self.directory = directory
        memory.totalCostLimit = 48 * 1024 * 1024
    }

    public static var defaultDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return caches.appending(path: "PalMediaPosters", directoryHint: .isDirectory)
    }

    public func cached(_ key: MediaPosterKey) -> MediaPreview? {
        memory.object(forKey: key.stem as NSString)?.preview
    }

    public func load(_ key: MediaPosterKey) async -> MediaPreview? {
        if let hit = cached(key) { return hit }
        let directory = directory
        let stem = key.stem
        let preview = await Task.detached(priority: .utility) { Self.read(stem: stem, in: directory) }.value
        if let preview { remember(preview, for: key) }
        return preview
    }

    public func store(_ preview: MediaPreview, for key: MediaPosterKey) async {
        remember(preview, for: key)
        let directory = directory
        let stem = key.stem
        await Task.detached(priority: .utility) { Self.write(preview, stem: stem, in: directory) }.value
    }

    public func removeAll() async {
        memory.removeAllObjects()
        let directory = directory
        _ = await Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: directory) }.value
    }

    private func remember(_ preview: MediaPreview, for key: MediaPosterKey) {
        memory.setObject(Entry(preview), forKey: key.stem as NSString, cost: preview.poster?.count ?? 1)
    }

    private static func read(stem: String, in directory: URL) -> MediaPreview? {
        let sidecarURL = directory.appending(path: "\(stem).json", directoryHint: .notDirectory)
        guard let sidecarData = try? Data(contentsOf: sidecarURL),
              let sidecar = try? JSONDecoder().decode(Sidecar.self, from: sidecarData)
        else { return nil }
        var poster: Data?
        if sidecar.hasPoster {
            guard let data = try? Data(contentsOf: directory.appending(path: "\(stem).jpg", directoryHint: .notDirectory)), !data.isEmpty
            else { return nil }
            poster = data
        }
        return MediaPreview(poster: poster, duration: sidecar.duration, size: sidecar.size, width: sidecar.width, height: sidecar.height)
    }

    private static func write(_ preview: MediaPreview, stem: String, in directory: URL) {
        let manager = FileManager.default
        guard (try? manager.createDirectory(at: directory, withIntermediateDirectories: true)) != nil else { return }
        let sidecar = Sidecar(
            duration: preview.duration, size: preview.size, width: preview.width, height: preview.height,
            hasPoster: preview.poster != nil
        )
        if let poster = preview.poster {
            guard (try? poster.write(to: directory.appending(path: "\(stem).jpg", directoryHint: .notDirectory), options: .atomic)) != nil
            else { return }
        }
        guard let encoded = try? JSONEncoder().encode(sidecar) else { return }
        try? encoded.write(to: directory.appending(path: "\(stem).json", directoryHint: .notDirectory), options: .atomic)
    }
}
