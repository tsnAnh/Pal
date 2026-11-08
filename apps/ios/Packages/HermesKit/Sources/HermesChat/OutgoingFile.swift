import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum AttachmentError: Error, Sendable, Equatable {
    case empty(name: String)
    case tooLarge(name: String)
    case unsupported(name: String)
    case tooMany
    case unreadable(name: String)
}

public enum AttachmentKind: Sendable, Equatable {
    case image
    case document
}

public struct PromptAttachment: Codable, Sendable, Hashable {
    public var name: String
    public var mime: String
    public var stored: String

    public init(name: String, mime: String, stored: String) {
        self.name = name
        self.mime = mime
        self.stored = stored
    }
}

public struct OutgoingFile: Sendable, Equatable {
    public static let maximumBytes = 25 * 1024 * 1024
    public static let maximumPerMessage = 10
    static let gatewayImageMIMEs: [String: String] = [
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp",
    ]

    public let name: String
    public let mime: String
    public let data: Data
    public let kind: AttachmentKind

    public init(name: String, mime: String, data: Data) throws(AttachmentError) {
        let clean = Self.sanitized(name)
        guard !data.isEmpty else { throw .empty(name: clean) }
        guard let type = Self.type(name: clean, mime: mime), !Self.isRefused(type) else { throw .unsupported(name: clean) }
        guard type.conforms(to: .image) else {
            try self.init(validated: clean, mime: mime, data: data, kind: .document)
            return
        }
        if let imageMIME = Self.gatewayImageMIMEs[Self.pathExtension(of: clean)] {
            try self.init(validated: clean, mime: imageMIME, data: data, kind: .image)
        } else if let jpeg = Self.jpeg(from: data) {
            try self.init(validated: Self.renamedAsJPEG(clean), mime: "image/jpeg", data: jpeg, kind: .image)
        } else {
            try self.init(validated: clean, mime: mime, data: data, kind: .document)
        }
    }

    private init(validated name: String, mime: String, data: Data, kind: AttachmentKind) throws(AttachmentError) {
        guard data.count <= Self.maximumBytes else { throw .tooLarge(name: name) }
        self.name = name
        self.mime = mime
        self.data = data
        self.kind = kind
    }

    static func sanitized(_ name: String) -> String {
        let last = name.split(separator: "/").last.map(String.init) ?? name
        let printable = last.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let cleaned = String(String.UnicodeScalarView(printable)).trimmingCharacters(in: .whitespaces)
        let bare = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return bare.isEmpty ? "attachment" : cleaned
    }

    private static func pathExtension(of name: String) -> String {
        (name as NSString).pathExtension.lowercased()
    }

    private static func type(name: String, mime: String) -> UTType? {
        let byName = UTType(filenameExtension: pathExtension(of: name))
        let byMime = UTType(mimeType: mime)
        if let byName, byName != .data { return byName }
        return byMime ?? byName ?? .data
    }

    private static func isRefused(_ type: UTType) -> Bool {
        type.conforms(to: .audiovisualContent) || type.conforms(to: .archive) || type.conforms(to: .executable)
            || type.conforms(to: .diskImage)
    }

    private static func renamedAsJPEG(_ name: String) -> String {
        let stem = (name as NSString).deletingPathExtension
        return (stem.isEmpty ? "image" : stem) + ".jpg"
    }

    private static func jpeg(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        let options = [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary
        CGImageDestinationAddImageFromSource(destination, source, 0, options)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}
