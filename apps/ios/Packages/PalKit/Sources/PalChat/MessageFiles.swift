import Foundation

public struct FileReference: Sendable, Hashable, Identifiable {
    public let path: String
    public let directive: String
    public let name: String
    public let typeLabel: String
    public let id: String

    public init(path: String, directive: String) {
        self.path = path
        self.directive = directive
        name = MessageFiles.fileName(of: path)
        typeLabel = MessageFiles.typeLabel(of: path)
        id = MessageFiles.assetRef(forHostPath: path)
    }
}

public enum FileAvailability: Sendable, Equatable {
    case available
    case unavailable
}

public enum MessageFiles {
    private static let tag = "MEDIA:"
    private static let previewPrefix = "::preview{"
    private static let maxPathLength = 2048
    private static let trailingMarks = CharacterSet(charactersIn: ".,;:!?'\"*_`)]}>")
    private static let leftToOtherRenderers = MessageImages.imageExtensions
    static let audioExtensions: Set<String> = ["mp3", "wav", "ogg", "oga", "opus", "m4a", "aac", "flac"]
    static let videoExtensions: Set<String> = ["mp4", "m4v", "mov", "webm", "mkv", "avi"]
    private static let mediaExtensions = audioExtensions.union(videoExtensions)

    public static func extract(from text: String, isStreaming: Bool) -> (text: String, files: [FileReference]) {
        guard text.contains(tag) || text.contains(previewPrefix) else { return (text, []) }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var kept: [String] = []
        var files: [FileReference] = []
        var fence: Character?
        for (index, line) in lines.enumerated() {
            let source = String(line)
            if let marker = fenceMarker(of: source) {
                if fence == nil { fence = marker } else if fence == marker { fence = nil }
                kept.append(source)
                continue
            }
            if fence == nil, let path = previewPath(in: source) {
                files.append(FileReference(path: path, directive: source.trimmingCharacters(in: .whitespaces)))
                continue
            }
            guard fence == nil, source.contains(tag) else {
                kept.append(source)
                continue
            }
            let isLast = index == lines.count - 1
            let result = strip(source, mayBePartial: isStreaming && isLast)
            files += result.files
            guard !result.files.isEmpty else {
                kept.append(source)
                continue
            }
            if !result.line.isEmpty { kept.append(result.line) }
        }
        guard !files.isEmpty else { return (text, []) }
        var seen: Set<String> = []
        let unique = files.filter { seen.insert($0.id).inserted }
        return (kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), unique)
    }

    public static func assetRef(forHostPath path: String) -> String {
        ImageReference.digest(of: Data("\(assetKind(of: path))\u{0}\(path)".utf8))
    }

    static func fileName(of path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    static func typeLabel(of path: String) -> String {
        let ext = (path as NSString).pathExtension
        return ext.isEmpty ? "File" : ext.uppercased()
    }

    private static func assetKind(of path: String) -> String {
        mediaExtensions.contains((path as NSString).pathExtension.lowercased()) ? "media" : "file"
    }

    private static func fenceMarker(of line: String) -> Character? {
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        if trimmed.hasPrefix("```") { return "`" }
        if trimmed.hasPrefix("~~~") { return "~" }
        return nil
    }

    private static func strip(_ line: String, mayBePartial: Bool) -> (line: String, files: [FileReference]) {
        var result = line
        var files: [FileReference] = []
        var search = result.startIndex..<result.endIndex
        while let found = result.range(of: tag, range: search) {
            var cursor = found.upperBound
            while cursor < result.endIndex, result[cursor] == " " || result[cursor] == "\t" { cursor = result.index(after: cursor) }
            let start = cursor
            while cursor < result.endIndex, !result[cursor].isWhitespace { cursor = result.index(after: cursor) }
            let insideInlineCode = result[..<found.lowerBound].filter { $0 == "`" }.count % 2 == 1
            let partial = mayBePartial && cursor == result.endIndex
            guard !insideInlineCode, !partial, let path = hostPath(from: String(result[start..<cursor])) else {
                search = cursor..<result.endIndex
                continue
            }
            files.append(FileReference(path: path, directive: String(result[found.lowerBound..<cursor])))
            result.removeSubrange(found.lowerBound..<cursor)
            search = found.lowerBound..<result.endIndex
        }
        let trimmed = result.trimmingCharacters(in: .whitespaces)
        return (trimmed, files)
    }

    private static func previewPath(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(previewPrefix), trimmed.hasSuffix("}") else { return nil }
        let attributes = trimmed.dropFirst(previewPrefix.count).dropLast()
        var search = attributes.startIndex..<attributes.endIndex
        while let key = attributes.range(of: "file=", range: search) {
            let atBoundary = key.lowerBound == attributes.startIndex || attributes[attributes.index(before: key.lowerBound)].isWhitespace
            if atBoundary, let quote = attributes[key.upperBound...].first, quote == "\"" || quote == "'" {
                let valueStart = attributes.index(after: key.upperBound)
                if let close = attributes[valueStart...].firstIndex(of: quote) {
                    return hostPath(from: String(attributes[valueStart..<close]))
                }
            }
            search = key.upperBound..<attributes.endIndex
        }
        return nil
    }

    private static func hostPath(from token: String) -> String? {
        let path = token.trimmingCharacters(in: trailingMarks)
        guard path.hasPrefix("/"), path.count > 1, !path.hasSuffix("/"), path.count <= maxPathLength,
              !path.contains("://"), !path.contains("\u{0}")
        else { return nil }
        let ext = (path as NSString).pathExtension.lowercased()
        return leftToOtherRenderers.contains(ext) ? nil : path
    }
}
