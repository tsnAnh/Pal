import CoreGraphics
import Foundation

public enum MediaKind: String, Sendable, Equatable, CaseIterable {
    case image
    case video
    case audio
    case pdf
    case document
    case archive
    case model3D
    case other

    private static let audioExtensions = MessageFiles.audioExtensions.union(["aiff"])
    private static let archiveExtensions: Set<String> = ["zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "zst"]
    private static let model3DExtensions: Set<String> = ["usdz", "obj", "stl"]
    private static let documentExtensions: Set<String> = [
        "rtf", "rtfd", "txt", "md", "markdown", "csv", "tsv", "json", "xml", "yaml", "yml", "toml", "ini", "log",
        "html", "htm", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key", "odt", "ods", "odp",
    ]
    private static let archiveMimeTypes: Set<String> = [
        "application/zip", "application/gzip", "application/x-gzip", "application/x-tar", "application/x-bzip2",
        "application/x-xz", "application/x-7z-compressed", "application/vnd.rar", "application/x-rar-compressed",
        "application/zstd",
    ]
    private static let documentMimeTypes: Set<String> = ["application/rtf", "application/msword", "application/json", "application/xml"]

    public init(fileName: String, mimeType: String? = nil) {
        if let mimeType, let kind = Self.init(mimeType: mimeType) {
            self = kind
            return
        }
        self.init(fileExtension: (fileName as NSString).pathExtension)
    }

    public init?(mimeType: String) {
        let mime = mimeType.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        if mime.hasPrefix("image/") {
            self = .image
        } else if mime.hasPrefix("video/") {
            self = .video
        } else if mime.hasPrefix("audio/") {
            self = .audio
        } else if mime.hasPrefix("model/") {
            self = .model3D
        } else if mime == "application/pdf" {
            self = .pdf
        } else if Self.archiveMimeTypes.contains(mime) {
            self = .archive
        } else if mime.hasPrefix("text/") || Self.documentMimeTypes.contains(mime)
                    || mime.hasPrefix("application/vnd.openxmlformats-officedocument.")
                    || mime.hasPrefix("application/vnd.oasis.opendocument.")
                    || mime.hasPrefix("application/vnd.ms-") {
            self = .document
        } else {
            return nil
        }
    }

    private init(fileExtension: String) {
        let ext = fileExtension.lowercased()
        if MessageImages.imageExtensions.contains(ext) {
            self = .image
        } else if MessageFiles.videoExtensions.contains(ext) {
            self = .video
        } else if Self.audioExtensions.contains(ext) {
            self = .audio
        } else if ext == "pdf" {
            self = .pdf
        } else if Self.archiveExtensions.contains(ext) {
            self = .archive
        } else if Self.model3DExtensions.contains(ext) {
            self = .model3D
        } else if Self.documentExtensions.contains(ext) {
            self = .document
        } else {
            self = .other
        }
    }

    public var rendersInline: Bool { self == .video || self == .audio }
}

public enum MediaLimits {
    public static let thumbnailSourceBytes = 32_000_000
    public static let downloadBytes = 200_000_000
    public static let chunkBytes = 2_000_000

    public static func allowsThumbnail(size: Int) -> Bool { size <= thumbnailSourceBytes }

    public static func allowsDownload(size: Int) -> Bool { size <= downloadBytes }
}

public struct MediaReference: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let kind: MediaKind
    public let size: Int?
    public let duration: TimeInterval?

    public init(id: String, name: String, kind: MediaKind, size: Int? = nil, duration: TimeInterval? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.size = size
        self.duration = duration
    }

    public init(file: FileReference, size: Int? = nil, duration: TimeInterval? = nil) {
        self.init(id: file.id, name: file.name, kind: MediaKind(fileName: file.name), size: size, duration: duration)
    }

    public static func split(_ files: [FileReference]) -> (media: [MediaReference], rest: [FileReference]) {
        var media: [MediaReference] = []
        var rest: [FileReference] = []
        for file in files {
            let reference = MediaReference(file: file)
            if reference.kind.rendersInline { media.append(reference) } else { rest.append(file) }
        }
        return (media, rest)
    }
}

public enum MediaTileMetrics {
    public static let single: CGFloat = 220
    public static let singleHeight: CGFloat = 165
    public static let tile: CGFloat = 108
    public static let spacing: CGFloat = 4
}
