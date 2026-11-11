import CryptoKit
import Foundation

public struct ImageReference: Sendable, Hashable, Identifiable {
    public enum Source: Sendable, Hashable {
        case hostPath(String)
        case remote(URL)
        case inline(Data)
    }

    public let source: Source
    public let name: String
    public let id: String

    public init(source: Source) {
        self.source = source
        switch source {
        case .hostPath(let path):
            id = Self.assetRef(forHostPath: path)
            name = Self.lastComponent(path)
        case .remote(let url):
            id = url.absoluteString
            name = Self.lastComponent(url.path)
        case .inline(let data):
            id = "inline:" + Self.digest(of: data)
            name = "image"
        }
    }

    public var assetRef: String? {
        if case .hostPath = source { id } else { nil }
    }

    public static func assetRef(forHostPath path: String) -> String {
        digest(of: Data("media\u{0}\(path)".utf8))
    }

    private static func digest(of data: Data) -> String {
        SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private static func lastComponent(_ path: String) -> String {
        let name = path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? ""
        return name.isEmpty ? "image" : name
    }
}

public struct MessageContent: Sendable, Hashable {
    public var text: String
    public var images: [ImageReference]
}

public enum MessageImages {
    public enum Role: Sendable {
        case user
        case assistant
    }

    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "heic", "heif", "tif", "tiff"]

    public static func extract(from text: String, role: Role) -> MessageContent {
        switch role {
        case .user: extractFromUser(text)
        case .assistant: extractFromAssistant(text)
        }
    }

    private static func extractFromUser(_ text: String) -> MessageContent {
        var kept: [Substring] = []
        var images: [ImageReference] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let reference = userReference(in: trimmed) {
                images.append(reference)
            } else {
                kept.append(line)
            }
        }
        guard !images.isEmpty else { return MessageContent(text: text, images: []) }
        let body = kept.filter { $0.trimmingCharacters(in: .whitespaces) != "[screenshot]" }
        return MessageContent(text: tidy(body.joined(separator: "\n")), images: unique(images))
    }

    private static func userReference(in line: String) -> ImageReference? {
        if line.hasPrefix("@image:") {
            return reference(forPath: unquote(String(line.dropFirst("@image:".count))))
        }
        if line.hasPrefix("[Image attached at: "), line.hasSuffix("]") {
            return reference(forPath: String(line.dropFirst("[Image attached at: ".count).dropLast()))
        }
        return inlineReference(in: line) ?? remoteImageReference(in: line)
    }

    private static func extractFromAssistant(_ text: String) -> MessageContent {
        var body = text
        var images: [ImageReference] = []
        var search = body.startIndex..<body.endIndex
        while let tag = body.range(of: "MEDIA:", range: search) {
            var cursor = tag.upperBound
            while cursor < body.endIndex, body[cursor] == " " || body[cursor] == "\t" { cursor = body.index(after: cursor) }
            let tokenStart = cursor
            while cursor < body.endIndex, !body[cursor].isWhitespace { cursor = body.index(after: cursor) }
            let token = String(body[tokenStart..<cursor]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)]}>"))
            if let reference = reference(forPath: unquote(token)) ?? remoteImageReference(in: token) {
                images.append(reference)
                body.removeSubrange(tag.lowerBound..<cursor)
                search = tag.lowerBound..<body.endIndex
            } else {
                search = cursor..<body.endIndex
            }
        }
        var kept: [Substring] = []
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            if let inline = inlineReference(in: line.trimmingCharacters(in: .whitespaces)) {
                images.append(inline)
            } else {
                kept.append(line)
            }
        }
        guard !images.isEmpty else { return MessageContent(text: text, images: []) }
        return MessageContent(text: tidy(kept.joined(separator: "\n")), images: unique(images))
    }

    private static func reference(forPath raw: String) -> ImageReference? {
        let path = raw.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty, !path.contains("\u{0}") else { return nil }
        if path.lowercased().hasPrefix("http://") || path.lowercased().hasPrefix("https://") {
            return remoteImageReference(in: path)
        }
        guard !path.contains("://"), !path.lowercased().hasPrefix("data:") else { return nil }
        let ext = (path as NSString).pathExtension.lowercased()
        guard imageExtensions.contains(ext) else { return nil }
        return ImageReference(source: .hostPath(path))
    }

    private static func remoteImageReference(in text: String) -> ImageReference? {
        guard text.lowercased().hasPrefix("https://") || text.lowercased().hasPrefix("http://"),
              !text.contains(where: \.isWhitespace),
              let url = URL(string: text), url.host() != nil,
              imageExtensions.contains(url.pathExtension.lowercased())
        else { return nil }
        return ImageReference(source: .remote(url))
    }

    private static func inlineReference(in line: String) -> ImageReference? {
        guard line.hasPrefix("data:image/"), let marker = line.range(of: ";base64,") else { return nil }
        let payload = String(line[marker.upperBound...])
        guard let data = Data(base64Encoded: payload), !data.isEmpty else { return nil }
        return ImageReference(source: .inline(data))
    }

    private static func unquote(_ value: String) -> String {
        guard let first = value.first, "`\"'".contains(first) else { return value }
        let rest = value.dropFirst()
        guard let end = rest.firstIndex(of: first) else { return value }
        return String(rest[rest.startIndex..<end])
    }

    private static func unique(_ images: [ImageReference]) -> [ImageReference] {
        var seen: Set<String> = []
        return images.filter { seen.insert($0.id).inserted }
    }

    private static func tidy(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
