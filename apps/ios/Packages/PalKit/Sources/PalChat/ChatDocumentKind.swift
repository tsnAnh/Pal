import CoreGraphics
import Foundation

public enum ChatDocumentKind: String, Sendable, Equatable, CaseIterable {
    case pdf
    case office
    case text
    case code
    case csv

    private static let extensions: [ChatDocumentKind: Set<String>] = [
        .pdf: ["pdf"],
        .office: ["doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key", "odt", "ods", "odp"],
        .text: ["txt", "md", "markdown", "rtf", "rtfd", "log"],
        .code: [
            "json", "xml", "yaml", "yml", "toml", "ini", "css", "js", "jsx", "ts", "tsx", "swift", "py", "rb", "go",
            "rs", "java", "kt", "c", "h", "cpp", "hpp", "m", "mm", "sh", "sql",
        ],
        .csv: ["csv", "tsv"],
    ]

    private static let byExtension: [String: ChatDocumentKind] = Self.extensions.reduce(into: [:]) { table, entry in
        for ext in entry.value { table[ext] = entry.key }
    }

    public init?(fileName: String) {
        guard let kind = Self.byExtension[(fileName as NSString).pathExtension.lowercased()] else { return nil }
        self = kind
    }

    public var spokenName: String {
        switch self {
        case .pdf: "PDF document"
        case .office: "Office document"
        case .text: "Text file"
        case .code: "Code file"
        case .csv: "CSV spreadsheet"
        }
    }

    public var iconName: String {
        switch self {
        case .pdf, .office, .text: "doc.text"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .csv: "tablecells"
        }
    }
}

public enum DocumentCardMetrics {
    public static let width: CGFloat = 240
    public static let thumbnailHeight: CGFloat = 150
    public static let thumbnailPixels = Int(width * 3)
}

public struct DocumentStrip: Sendable, Equatable {
    public static let openHint = "Double tap to open"

    public let name: String
    public let typeLabel: String
    public let pageCount: Int?
    public let size: Int?
    public let kind: ChatDocumentKind

    public init(name: String, typeLabel: String, kind: ChatDocumentKind, pageCount: Int? = nil, size: Int? = nil) {
        self.name = name
        self.typeLabel = typeLabel
        self.kind = kind
        self.pageCount = pageCount
        self.size = size
    }

    public var pages: String? {
        guard let pageCount, pageCount > 0 else { return nil }
        return pageCount == 1 ? "1 page" : "\(pageCount) pages"
    }

    public var detail: String {
        [typeLabel, pages, size.map(MediaSize.label)].compactMap { $0 }.joined(separator: ", ")
    }

    public var accessibilityLabel: String {
        [kind.spokenName, name, pages].compactMap { $0 }.joined(separator: ", ")
    }

    public func with(_ preview: MediaPreview?) -> DocumentStrip {
        DocumentStrip(name: name, typeLabel: typeLabel, kind: kind, pageCount: preview?.pageCount ?? pageCount, size: preview?.size ?? size)
    }
}
