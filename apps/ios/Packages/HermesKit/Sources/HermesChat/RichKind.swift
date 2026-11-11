import Foundation

public enum RichKind: Sendable, Equatable {
    case code(language: String?)
    case diff
    case terminal
    case json
    case mermaid
    case latex
    case plain
}

public enum RichClassifier {
    private static let diffLanguages: Set<String> = ["diff", "patch", "udiff"]
    private static let mermaidLanguages: Set<String> = ["mermaid", "mmd"]
    private static let latexLanguages: Set<String> = ["latex", "tex", "math", "katex"]
    private static let jsonLanguages: Set<String> = ["json", "jsonc", "json5"]
    private static let terminalLanguages: Set<String> = ["ansi", "terminal", "console", "term", "output", "log"]
    private static let sniffableLanguages: Set<String> = ["text", "txt", "plain", "plaintext", "none"]

    public static func classify(language: String?, body: String) -> RichKind {
        let normalized = normalize(language)
        if containsCSI(body) { return .terminal }
        if let normalized {
            if diffLanguages.contains(normalized) { return .diff }
            if mermaidLanguages.contains(normalized) { return .mermaid }
            if latexLanguages.contains(normalized) { return .latex }
            if terminalLanguages.contains(normalized) { return .terminal }
            if jsonLanguages.contains(normalized) {
                return JSONPretty.isValidContainer(body) ? .json : .code(language: normalized)
            }
            if !sniffableLanguages.contains(normalized), CodeLanguageSpecs.resolve(normalized) != nil {
                return .code(language: normalized)
            }
        }
        if looksLikeUnifiedDiff(body) { return .diff }
        if JSONPretty.isValidContainer(body) { return .json }
        return .code(language: normalized)
    }

    static func normalize(_ language: String?) -> String? {
        guard let word = language?.split(whereSeparator: \.isWhitespace).first else { return nil }
        let lowered = word.lowercased()
        return lowered.isEmpty ? nil : lowered
    }

    private static func containsCSI(_ body: String) -> Bool {
        var sawEscape = false
        for byte in body.utf8 {
            if sawEscape, byte == UInt8(ascii: "[") { return true }
            sawEscape = byte == 0x1B
        }
        return false
    }

    private static func looksLikeUnifiedDiff(_ body: String) -> Bool {
        var previousWasOldHeader = false
        for line in body.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("diff --git") { return true }
            if previousWasOldHeader, line.hasPrefix("+++ ") { return true }
            previousWasOldHeader = line.hasPrefix("--- ")
            if isHunkHeader(line) { return true }
        }
        return false
    }

    private static func isHunkHeader(_ line: Substring) -> Bool {
        guard line.hasPrefix("@@ -") else { return false }
        let rest = line.dropFirst(4)
        guard let plus = rest.range(of: " +") else { return false }
        return rest[plus.upperBound...].contains("@@") && rest[..<plus.lowerBound].first?.isNumber == true
    }
}

public extension MarkdownBlock {
    var richKind: RichKind {
        switch kind {
        case .code(let language): RichClassifier.classify(language: language, body: String(text.characters))
        case .math: .latex
        case .paragraph, .heading, .thematicBreak: .plain
        }
    }

    var standaloneLink: URL? {
        guard kind == .paragraph, lists.isEmpty, !isQuoted else { return nil }
        var runs = text.runs.makeIterator()
        guard let run = runs.next(), runs.next() == nil else { return nil }
        if let link = run.link { return Self.webURL(link) }
        guard run.inlinePresentationIntent == nil else { return nil }
        let raw = String(text.characters)
        guard !raw.contains(where: \.isWhitespace), raw.count <= 2_048 else { return nil }
        return URL(string: raw).flatMap(Self.webURL)
    }

    private static func webURL(_ url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host() != nil
        else { return nil }
        return url
    }
}
