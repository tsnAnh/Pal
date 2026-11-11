import Foundation

public enum DiffLineKind: Sendable {
    case added
    case removed
    case context
    case hunk
    case fileHeader
    case meta
}

public struct DiffLine: Sendable, Equatable {
    public var kind: DiffLineKind
    public var text: String

    public init(kind: DiffLineKind, text: String) {
        self.kind = kind
        self.text = text
    }
}

public enum DiffParser {
    private static let fileHeaderPrefixes = ["diff --git", "--- ", "+++ "]
    private static let metaPrefixes = [
        "index ", "similarity ", "dissimilarity ", "rename ", "copy ", "new file", "deleted file",
        "old mode", "new mode", "Binary files",
    ]

    public static func parse(_ source: String) -> [DiffLine] {
        var rows = source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        if rows.last?.isEmpty == true { rows.removeLast() }
        var output: [DiffLine] = []
        output.reserveCapacity(rows.count)
        var sawHunk = false
        var inHunk = false

        for (offset, row) in rows.enumerated() {
            let line = String(row)
            if row.hasPrefix("diff --git") {
                output.append(DiffLine(kind: .fileHeader, text: line))
                inHunk = false
                continue
            }
            if row.hasPrefix("@@") {
                output.append(DiffLine(kind: .hunk, text: line))
                sawHunk = true
                inHunk = true
                continue
            }
            if row.hasPrefix("\\") {
                output.append(DiffLine(kind: .meta, text: line))
                continue
            }
            if !inHunk, let header = headerKind(row) {
                output.append(DiffLine(kind: header, text: line))
                continue
            }
            if sawHunk, startsNewFile(rows, at: offset) {
                output.append(DiffLine(kind: .fileHeader, text: line))
                inHunk = false
                continue
            }
            output.append(content(row))
        }
        return output
    }

    public static func stats(_ lines: [DiffLine]) -> (added: Int, removed: Int) {
        var added = 0
        var removed = 0
        for line in lines {
            switch line.kind {
            case .added: added += 1
            case .removed: removed += 1
            default: break
            }
        }
        return (added, removed)
    }

    private static func headerKind(_ row: Substring) -> DiffLineKind? {
        if fileHeaderPrefixes.contains { row.hasPrefix($0) } { return .fileHeader }
        if metaPrefixes.contains { row.hasPrefix($0) } { return .meta }
        if isArrowHeader(row) { return .fileHeader }
        return nil
    }

    private static func isArrowHeader(_ row: Substring) -> Bool {
        guard let first = row.first, first != "+", first != "-", first != "@", first != " " else { return false }
        let parts = row.components(separatedBy: "→")
        return parts.count == 2 && !parts[0].trimmingCharacters(in: .whitespaces).isEmpty
            && !parts[1].trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static func startsNewFile(_ rows: [Substring], at offset: Int) -> Bool {
        guard rows[offset].hasPrefix("--- "), offset + 2 < rows.count else { return false }
        return rows[offset + 1].hasPrefix("+++ ") && rows[offset + 2].hasPrefix("@@")
    }

    private static func content(_ row: Substring) -> DiffLine {
        guard let marker = row.first else { return DiffLine(kind: .context, text: "") }
        switch marker {
        case "+": return DiffLine(kind: .added, text: String(row.dropFirst()))
        case "-": return DiffLine(kind: .removed, text: String(row.dropFirst()))
        case " ": return DiffLine(kind: .context, text: String(row.dropFirst()))
        default: return DiffLine(kind: .context, text: String(row))
        }
    }
}
