import Foundation

public enum KanbanRef {
    public static func normalized(_ text: String) -> String {
        text.uppercased().replacingOccurrences(of: "-", with: "")
    }

    static func isRef(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, let prefix = parts.first, let number = parts.last else { return false }
        return !prefix.isEmpty && prefix.allSatisfy { $0.isASCII && $0.isLetter } && !number.isEmpty && number.allSatisfy { $0.isASCII && $0.isNumber }
    }

    public static func ranges(in text: String) -> [Range<String.Index>] {
        guard let regex = try? NSRegularExpression(pattern: #"\b[A-Za-z]+-[0-9]+\b"#) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range, in: text) }
    }

    public static func index(rows: [KanbanCardRow]) -> [String: String] {
        var index: [String: String] = [:]
        for row in rows.sorted(by: { $0.card.taskID < $1.card.taskID }) {
            guard let ref = row.ref else { continue }
            let key = normalized(ref)
            if index[key] == nil { index[key] = row.card.taskID }
        }
        return index
    }
}
