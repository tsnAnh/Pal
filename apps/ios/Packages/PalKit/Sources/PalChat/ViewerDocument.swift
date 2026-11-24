import Foundation
import PalDiagnostics

public enum DocumentKind: Sendable, Equatable {
    case markdown
    case plainText

    private static let markdownExtensions: Set<String> = ["md", "markdown"]
    private static let plainTextExtensions: Set<String> = [
        "txt", "json", "yaml", "yml", "toml", "ini", "log", "xml", "css",
        "js", "jsx", "ts", "tsx", "swift", "py", "rb", "go", "rs", "java", "kt",
        "c", "h", "cpp", "hpp", "m", "mm", "sh", "sql",
    ]

    public init?(fileName: String) {
        let ext = (fileName as NSString).pathExtension.lowercased()
        if Self.markdownExtensions.contains(ext) {
            self = .markdown
        } else if Self.plainTextExtensions.contains(ext) {
            self = .plainText
        } else {
            return nil
        }
    }
}

public enum FileOpenRoute: Sendable, Equatable {
    case viewer(DocumentKind)
    case html
    case sheet

    public init(fileName: String, viewerShowsDocuments: Bool) {
        if ChatDocumentKind(fileName: fileName) == .html {
            self = .html
        } else if viewerShowsDocuments, let kind = DocumentKind(fileName: fileName) {
            self = .viewer(kind)
        } else {
            self = .sheet
        }
    }
}

public struct DocumentText: Sendable, Equatable {
    public static let cap = 2 * 1024 * 1024

    public let text: String
    public let totalBytes: Int
    public let cap: Int

    public init(data: Data, cap: Int = DocumentText.cap) {
        self.cap = cap
        totalBytes = data.count
        let truncated = data.count > cap
        text = Self.decode(truncated ? Data(data.prefix(cap)) : data, mayEndMidScalar: truncated)
    }

    public var isTruncated: Bool { totalBytes > cap }

    public var isEmpty: Bool { text.allSatisfy(\.isWhitespace) }

    public var truncationNote: String? {
        guard isTruncated else { return nil }
        let shown = ByteCountFormatter.string(fromByteCount: Int64(cap), countStyle: .memory)
        let total = ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .memory)
        return String(localized: "Showing the first \(shown) of \(total). Download the file to read the rest.")
    }

    private static func decode(_ data: Data, mayEndMidScalar: Bool) -> String {
        var end = data.count
        let floor = mayEndMidScalar ? max(0, end - 3) : end
        while true {
            if let text = String(data: data.prefix(end), encoding: .utf8) { return text }
            guard end > floor else { return String(data: data, encoding: .isoLatin1) ?? "" }
            end -= 1
        }
    }
}

public struct DocumentTextChunk: Sendable, Equatable, Identifiable {
    public let id: Int
    public let text: String
}

public enum DocumentTextChunks {
    public static let linesPerChunk = 200
    public static let charactersPerChunk = 16_000

    public static func split(
        _ text: String, linesPerChunk: Int = DocumentTextChunks.linesPerChunk,
        charactersPerChunk: Int = DocumentTextChunks.charactersPerChunk
    ) -> [DocumentTextChunk] {
        guard !text.isEmpty else { return [] }
        var chunks: [DocumentTextChunk] = []
        var lines: [Substring] = []
        var size = 0
        func flush() {
            guard !lines.isEmpty else { return }
            chunks.append(DocumentTextChunk(id: chunks.count, text: lines.joined(separator: "\n")))
            lines.removeAll(keepingCapacity: true)
            size = 0
        }
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            lines.append(line)
            size += line.count + 1
            if lines.count >= max(1, linesPerChunk) || size >= max(1, charactersPerChunk) { flush() }
        }
        flush()
        return chunks
    }
}

public enum DocumentLinkTarget: Sendable, Equatable {
    case chatFile(FileReference)
    case web(URL)
    case sameDocument
    case unreachable
}

public enum DocumentLink {
    private static let webSchemes: Set<String> = ["http", "https", "mailto"]

    public static func classify(_ url: URL, from current: FileReference, chatFiles: [FileReference]) -> DocumentLinkTarget {
        if let scheme = url.scheme?.lowercased(), scheme != "file" {
            return webSchemes.contains(scheme) ? .web(url) : .unreachable
        }
        let path = url.path
        if path.isEmpty { return url.fragment == nil ? .unreachable : .sameDocument }
        let target = resolved(path, relativeTo: current.path)
        let match = chatFiles.first { resolved($0.path, relativeTo: "/") == target }
        return match.map(DocumentLinkTarget.chatFile) ?? .unreachable
    }

    public static func hidingUnreachable(
        _ items: [MarkdownLayoutItem], from current: FileReference, chatFiles: [FileReference]
    ) -> [MarkdownLayoutItem] {
        items.map { (item: MarkdownLayoutItem) -> MarkdownLayoutItem in
            switch item {
            case .block(let block):
                .block(hiding(block, from: current, chatFiles: chatFiles))
            case .quote(let blocks):
                .quote(blocks: blocks.map { hiding($0, from: current, chatFiles: chatFiles) })
            }
        }
    }

    private static func hiding(_ block: MarkdownBlock, from current: FileReference, chatFiles: [FileReference]) -> MarkdownBlock {
        let links = block.text.runs[\.link]
        guard links.contains(where: { $0.0 != nil }) else { return block }
        var rewritten = AttributedString()
        for (link, range) in links {
            var piece = AttributedString(block.text[range])
            if let link, classify(link, from: current, chatFiles: chatFiles) == .unreachable {
                piece.link = nil
                rewritten += piece
                rewritten += AttributedString(" (" + String(localized: "File not available in this chat") + ")")
            } else {
                rewritten += piece
            }
        }
        var copy = block
        copy.text = rewritten
        return copy
    }

    private static func resolved(_ path: String, relativeTo anchor: String) -> String {
        let absolute = path.hasPrefix("/") ? path : (anchor as NSString).deletingLastPathComponent + "/" + path
        return URL(fileURLWithPath: absolute).standardized.path
    }
}

public struct ViewerDocument: Sendable, Equatable {
    public enum Body: Sendable, Equatable {
        case empty
        case markdown([MarkdownLayoutItem])
        case plainText([DocumentTextChunk])
    }

    public let body: Body
    public let note: String?

    public init(data: Data, kind: DocumentKind, file: FileReference, chatFiles: [FileReference]) {
        let perf = PalPerf.begin("viewer.document.build"); defer { perf.end() }
        let document = DocumentText(data: data)
        note = document.truncationNote
        guard !document.isEmpty else {
            body = .empty
            return
        }
        switch kind {
        case .markdown:
            let items = MarkdownDocument(parsing: document.text).layoutItems
            body = .markdown(DocumentLink.hidingUnreachable(items, from: file, chatFiles: chatFiles))
        case .plainText:
            body = .plainText(DocumentTextChunks.split(document.text))
        }
    }
}

public struct DocumentViewerState: Sendable, Equatable {
    public static let actions: [ViewerAction] = [.download, .close]

    public let file: FileReference
    public let kind: DocumentKind
    public let chatFiles: [FileReference]

    public init?(file: FileReference, chatFiles: [FileReference]) {
        guard let kind = DocumentKind(fileName: file.name) else { return nil }
        self.file = file
        self.kind = kind
        self.chatFiles = chatFiles
    }

    public var title: String { file.name }

    public var accessibilityName: String { String(localized: "Document \(file.name)") }

    public func opening(_ other: FileReference) -> DocumentViewerState? {
        DocumentViewerState(file: other, chatFiles: chatFiles)
    }
}

public enum DocumentViewerSend {
    private static let needsQuoting = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "()[]{}<>\"'`"))

    public static func body(file: FileReference, draft: String) -> String? {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return "\(reference(to: file))\n\(text)"
    }

    private static func reference(to file: FileReference) -> String {
        let quoted = file.path.rangeOfCharacter(from: needsQuoting) != nil && !file.path.contains("`")
        return quoted ? "@file:`\(file.path)`" : "@file:\(file.path)"
    }
}
