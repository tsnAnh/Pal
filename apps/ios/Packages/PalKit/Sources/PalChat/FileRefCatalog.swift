import Foundation
import PalProtocol

/// One row of the composer's `@` picker: a `complete.path` entry such as `@file:src/main.swift`,
/// `@folder:src/`, a starter (`@file:`) or a plain handle (`@diff`).
public struct FileRefItem: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case file
        case folder
        /// `@kind:` with no value yet: picking it keeps the picker open to browse that kind.
        case starter
        /// Any other row, inserted as the gateway wrote it.
        case other
    }

    /// The gateway's `text`, exactly as `complete.path` returned it.
    public var text: String
    public var display: String
    public var meta: String
    public var kind: Kind

    public var id: String { text }

    public init(text: String, display: String, meta: String, kind: Kind) {
        self.text = text
        self.display = display
        self.meta = meta
        self.kind = kind
    }

    /// The path or value after `@kind:`, with the folder's trailing slash kept.
    public var value: String {
        FileRefCatalog.split(text)?.value ?? ""
    }
}

/// What the `@` token at the end of the draft asks for.
public struct FileRefTrigger: Sendable, Hashable {
    /// Everything typed after `@`.
    public var query: String
    /// `file` or `folder` once the user typed `@file:` / `@folder:`.
    public var scope: String?
    /// The query without its scope: the part that is a path.
    public var value: String
    /// Characters the token occupies in the draft, `@` included.
    public var tokenLength: Int

    /// The `word` parameter of `complete.path`.
    public var word: String { "@" + query }
}

/// A `complete.path` answer and the word it answers, so a stale answer is never shown as current.
public struct FileRefResult: Sendable, Hashable {
    public var word: String
    public var items: [FileRefItem]

    public init(word: String, items: [FileRefItem]) {
        self.word = word
        self.items = items
    }
}

/// The `@` picker's pure logic, ported from the desktop composer: `composer/text-utils.ts`
/// (`AT_TRIGGER_RE`), `hooks/use-at-completions.ts` (`classify`), `directive-text.ts`
/// (`formatRefValue`, `hermesDirectiveFormatter.serialize`) and `use-composer-trigger.ts`
/// (Tab descends into a folder, Enter commits it).
public enum FileRefCatalog {
    static let maxItems = 50
    static let scopes: Set<String> = ["file", "folder"]

    // MARK: Trigger

    /// The `@` token at the end of the draft, or nil when the picker is closed. The token starts the
    /// draft or follows whitespace, so `me@host` and `a@b.com` never open it, and it stops at the
    /// first whitespace, so a finished reference followed by a space closes it.
    public static func trigger(in draft: String) -> FileRefTrigger? {
        let token = String(draft.reversed().prefix { !isBoundary($0) }.reversed())
        guard token.first == "@" else { return nil }
        let query = String(token.dropFirst())
        guard !query.contains("@") else { return nil }
        var scope: String?
        var value = query
        if let parts = split(token), scopes.contains(parts.kind) {
            scope = parts.kind
            value = parts.value
        }
        return FileRefTrigger(query: query, scope: scope, value: value, tokenLength: token.count)
    }

    private static func isBoundary(_ character: Character) -> Bool {
        character.isWhitespace || character == "\u{FFFC}"
    }

    // MARK: Parsing

    /// Reads a `complete.path` result.
    public static func parse(_ result: JSONValue) -> [FileRefItem] {
        var seen: Set<String> = []
        var items: [FileRefItem] = []
        for entry in result["items"]?.arrayValue ?? [] {
            guard let text = entry["text"]?.stringValue, !text.isEmpty, seen.insert(text).inserted else { continue }
            let parts = split(text)
            let kind: FileRefItem.Kind
            switch (parts?.kind, parts?.value.isEmpty) {
            case (_, true?): kind = .starter
            case ("file"?, _): kind = .file
            case ("folder"?, _): kind = .folder
            default: kind = .other
            }
            items.append(FileRefItem(
                text: text,
                display: entry["display"]?.stringValue ?? text,
                meta: entry["meta"]?.stringValue ?? "",
                kind: kind
            ))
            if items.count == maxItems { break }
        }
        return items
    }

    /// `@kind:value` as (kind, value); nil for a handle without a colon such as `@diff`.
    static func split(_ text: String) -> (kind: String, value: String)? {
        guard text.first == "@", let colon = text.firstIndex(of: ":") else { return nil }
        let kind = text[text.index(after: text.startIndex)..<colon]
        guard !kind.isEmpty, !kind.contains(where: { isBoundary($0) }) else { return nil }
        return (String(kind), String(text[text.index(after: colon)...]))
    }

    // MARK: Filtering

    /// Narrows `items` to what still matches `trigger` while the next answer is in flight: the last
    /// path segment typed must appear in a row's text or label. The gateway does the real ranking.
    public static func filter(_ items: [FileRefItem], trigger: FileRefTrigger) -> [FileRefItem] {
        let typed = trigger.scope == nil ? trigger.query : trigger.value
        let needle = typed.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init)?.lowercased() ?? ""
        guard !needle.isEmpty else { return items }
        return items.filter { $0.text.lowercased().contains(needle) || $0.display.lowercased().contains(needle) }
    }

    /// Rows for `trigger`: the answer to exactly its word, or, while a newer answer is in flight, the
    /// previous answer narrowed when the user only kept typing. Any other word's answer is stale.
    public static func visible(_ result: FileRefResult?, for trigger: FileRefTrigger) -> [FileRefItem] {
        guard let result else { return [] }
        if result.word == trigger.word { return result.items }
        return trigger.word.hasPrefix(result.word) ? filter(result.items, trigger: trigger) : []
    }

    /// True once the gateway has answered `trigger`'s own word, so an empty list is a real empty answer.
    public static func isSettled(_ result: FileRefResult?, for trigger: FileRefTrigger) -> Bool {
        result?.word == trigger.word
    }

    // MARK: Insertion

    public struct Replacement: Sendable, Hashable {
        public var draft: String
        /// True when the new token should list again (a starter or a folder entered with Tab).
        public var keepsOpen: Bool
    }

    /// The draft after the user picks `item` for `trigger`. A file or folder becomes `@file:path ` /
    /// `@folder:path ` with the path backtick-quoted when it has spaces or brackets, like Electron's
    /// chip text. `descend` (Tab on a folder) retypes the token as the bare `@path/` so the next
    /// `complete.path` lists that folder; a starter is inserted as is and stays open.
    public static func replacement(in draft: String, trigger: FileRefTrigger, item: FileRefItem, descend: Bool = false) -> Replacement {
        let head = String(draft.dropLast(trigger.tokenLength))
        if descend, item.kind == .folder {
            let path = item.value.hasSuffix("/") ? item.value : item.value + "/"
            let scope = trigger.scope.map { $0 + ":" } ?? ""
            return Replacement(draft: head + "@" + scope + path, keepsOpen: true)
        }
        switch item.kind {
        case .starter:
            return Replacement(draft: head + item.text, keepsOpen: true)
        case .file, .folder:
            let kind = item.kind == .file ? "file" : "folder"
            return Replacement(draft: head + "@\(kind):" + formatValue(item.value) + " ", keepsOpen: false)
        case .other:
            return Replacement(draft: head + serialized(item) + " ", keepsOpen: false)
        }
    }

    private static func serialized(_ item: FileRefItem) -> String {
        guard let parts = split(item.text) else { return item.text }
        return "@\(parts.kind):" + formatValue(parts.value)
    }

    /// `formatRefValue` from the desktop composer.
    static func formatValue(_ value: String) -> String {
        let special = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "()[]{}<>\"'`"))
        guard value.rangeOfCharacter(from: special) != nil else { return value }
        for quote in ["`", "\"", "'"] where !value.contains(quote) {
            return quote + value + quote
        }
        return value
    }
}
