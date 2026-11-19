import Foundation
import UniformTypeIdentifiers

public enum DropSource: Equatable, Sendable {
    case fileURL
    case image(typeIdentifier: String)
    case content(typeIdentifier: String)
    case webLink
    case text
    case unsupported

    public static let imagePreference = [
        "public.png",
        "public.jpeg",
        "public.heic",
        "public.tiff",
        "org.webmproject.webp",
        "public.image",
    ]

    public static func classify(typeIdentifiers: [String]) -> DropSource {
        if typeIdentifiers.contains(UTType.fileURL.identifier) { return .fileURL }
        if let image = imageType(in: typeIdentifiers) { return .image(typeIdentifier: image) }
        if let content = contentType(in: typeIdentifiers) { return .content(typeIdentifier: content) }
        if typeIdentifiers.contains(UTType.url.identifier) { return .webLink }
        if typeIdentifiers.contains(where: { UTType($0)?.conforms(to: .text) == true }) { return .text }
        return .unsupported
    }

    public var isAttachment: Bool {
        switch self {
        case .fileURL, .image, .content: true
        case .webLink, .text, .unsupported: false
        }
    }

    public static func carriesAttachment(typeIdentifiers: [String]) -> Bool {
        classify(typeIdentifiers: typeIdentifiers).isAttachment
    }

    private static func imageType(in identifiers: [String]) -> String? {
        if let preferred = imagePreference.first(where: identifiers.contains) { return preferred }
        return identifiers.first { UTType($0)?.conforms(to: .image) == true }
    }

    private static func contentType(in identifiers: [String]) -> String? {
        identifiers.first { identifier in
            guard !identifier.hasPrefix("dyn."), !identifier.hasPrefix("com.apple."), let type = UTType(identifier) else { return false }
            let isTextual = type.conforms(to: .text) || type.conforms(to: .url) || type.conforms(to: .html)
            return type.conforms(to: .data) && !isTextual
        }
    }
}

public enum DropFailure: Equatable, Sendable {
    case webLinkOnly
    case unsupported
    case unreadable
    case tooLarge(limitMegabytes: Int)
    case rejected(String)

    public var message: String {
        switch self {
        case .webLinkOnly: "That's a web link, not a file. Save the image first, then drop it here."
        case .unsupported: "This item can't be attached."
        case .unreadable: "That item couldn't be read."
        case .tooLarge(let limit): "That file is over \(limit) MB, so it was not attached."
        case .rejected(let reason): reason
        }
    }

    public static func summary(of failures: [DropFailure]) -> String? {
        guard let first = failures.first else { return nil }
        return failures.count == 1 ? first.message : "\(failures.count) items weren't attached. \(first.message)"
    }
}

public struct DropBatch: Equatable, Sendable {
    public var files: [URL]
    public var images: [Data]
    public var failures: [DropFailure]
    public var temporaryDirectories: [URL]

    public init(files: [URL] = [], images: [Data] = [], failures: [DropFailure] = [], temporaryDirectories: [URL] = []) {
        self.files = files
        self.images = images
        self.failures = failures
        self.temporaryDirectories = temporaryDirectories
    }

    public var isEmpty: Bool { files.isEmpty && images.isEmpty && failures.isEmpty }
}
