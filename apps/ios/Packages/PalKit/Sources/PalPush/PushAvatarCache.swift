import Foundation

public struct PushAvatarCache: Sendable {
    public static let groupIdentifier = "group.dev.tsnanh.hermes.bot"
    private static let directoryName = "PushAvatars"
    public static let maximumFileBytes = 512 * 1024

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static func shared(fileManager: FileManager = .default) -> PushAvatarCache? {
        fileManager.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier)
            .map { PushAvatarCache(directory: $0.appendingPathComponent(directoryName, isDirectory: true)) }
    }

    public func url(for profile: String) -> URL? {
        guard let stem = profile.addingPercentEncoding(withAllowedCharacters: .alphanumerics), !stem.isEmpty else { return nil }
        return directory.appendingPathComponent(stem + ".png", isDirectory: false)
    }

    public func image(for profile: String) -> Data? {
        guard let url = url(for: profile),
              let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
              (1...Self.maximumFileBytes).contains(size)
        else { return nil }
        return try? Data(contentsOf: url)
    }

    @discardableResult
    public func store(_ png: Data, for profile: String, fileManager: FileManager = .default) -> Bool {
        guard !png.isEmpty, png.count <= Self.maximumFileBytes, let url = url(for: profile) else { return false }
        if image(for: profile) == png { return true }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try png.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    public func prune(keeping profiles: Set<String>, fileManager: FileManager = .default) {
        let keep = Set(profiles.compactMap { url(for: $0)?.lastPathComponent })
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where !keep.contains(name) {
            try? fileManager.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
