import Foundation

public enum FilePreviewKind: Sendable, Equatable {
    case quickLook
    case saveOnly

    private static let previewable: Set<String> = MessageImages.imageExtensions.union([
        "pdf", "rtf", "rtfd", "txt", "md", "markdown", "csv", "tsv", "json", "xml", "yaml", "yml", "toml", "ini", "log",
        "html", "htm", "css", "js", "jsx", "ts", "tsx", "swift", "py", "rb", "go", "rs", "java", "kt", "c", "h", "cpp",
        "hpp", "m", "mm", "sh", "sql",
        "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key", "odt", "ods", "odp",
        "usdz", "vcf", "ics",
        "mp3", "wav", "ogg", "oga", "opus", "m4a", "aac", "flac", "aiff",
        "mp4", "m4v", "mov", "webm", "mkv", "avi",
    ])

    public init(fileName: String) {
        let ext = (fileName as NSString).pathExtension.lowercased()
        self = Self.previewable.contains(ext) ? .quickLook : .saveOnly
    }
}
