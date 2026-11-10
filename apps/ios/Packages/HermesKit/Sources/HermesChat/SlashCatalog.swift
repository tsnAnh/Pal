import Foundation
import HermesProtocol

/// One row of the composer's `/` picker: a gateway command or a skill.
public struct SlashItem: Sendable, Hashable, Identifiable {
    public enum Group: Int, Sendable, Hashable {
        case commands
        case skills

        public var title: String {
            switch self {
            case .commands: "Commands"
            case .skills: "Skills"
            }
        }
    }

    /// `/name`, always with the leading slash.
    public var command: String
    public var description: String
    public var group: Group
    /// Times the user has run the skill; ranks the bare `/` list.
    public var usage: Int
    /// A bundled skill never run: hidden from the bare `/` list, still found by typing.
    public var isUnusedBundled: Bool

    public var id: String { command }

    public init(command: String, description: String, group: Group, usage: Int = 0, isUnusedBundled: Bool = false) {
        self.command = command
        self.description = description
        self.group = group
        self.usage = usage
        self.isUnusedBundled = isUnusedBundled
    }
}

/// The `/` picker's pure logic, ported from the desktop composer: `apps/shared/src/slash-score.ts`
/// (tiered scoring), `slash-input.ts` (a `/` at position 0 is a command), and
/// `desktop-slash-commands.ts` `rankSkillCommands` / `slashCompletionGroup`.
public enum SlashCatalog {
    /// Categories the gateway files under the terminal UI, which a chat client cannot run.
    static let hiddenCategories: Set<String> = ["TUI"]

    // MARK: Trigger

    /// The name typed after a leading `/`, or nil when the picker is closed. Open only while `/` is the
    /// first character and no whitespace or second slash follows: past the command name the text is an
    /// argument, and `/usr/local` is a path.
    public static func query(in draft: String) -> String? {
        guard draft.first == "/" else { return nil }
        let rest = draft.dropFirst()
        guard !rest.contains(where: { $0.isWhitespace || $0 == "/" }) else { return nil }
        return String(rest)
    }

    /// The draft after the user picks `item`: the command and a trailing space for its argument.
    public static func insertion(for item: SlashItem) -> String {
        item.command + " "
    }

    // MARK: Parsing

    /// Reads a `commands.catalog` result. Categorised registry commands become Commands; commands that
    /// only appear in the flat `pairs` list are skills, ranked by usage as `rankSkillCommands` does.
    public static func parse(_ result: JSONValue) -> [SlashItem] {
        var commands: [SlashItem] = []
        var seen: Set<String> = []
        for category in result["categories"]?.arrayValue ?? [] {
            if hiddenCategories.contains(category["name"]?.stringValue ?? "") { continue }
            for pair in category["pairs"]?.arrayValue ?? [] {
                guard let entry = commandPair(pair), seen.insert(entry.command.lowercased()).inserted else { continue }
                commands.append(SlashItem(command: entry.command, description: entry.description, group: .commands))
            }
        }
        let skillInfo = result["skills"]?.objectValue ?? [:]
        var skills: [SlashItem] = []
        for pair in result["pairs"]?.arrayValue ?? [] {
            guard let entry = commandPair(pair), seen.insert(entry.command.lowercased()).inserted else { continue }
            let info = skillInfo[entry.command] ?? skillInfo[entry.command.lowercased()]
            let usage = info?["usage"]?.intValue ?? 0
            let bundled = info?["origin"]?.stringValue == "bundled"
            skills.append(SlashItem(
                command: entry.command,
                description: entry.description,
                group: .skills,
                usage: usage,
                isUnusedBundled: bundled && usage == 0
            ))
        }
        skills.sort { $0.usage != $1.usage ? $0.usage > $1.usage : $0.command < $1.command }
        return commands + skills
    }

    private static func commandPair(_ pair: JSONValue) -> (command: String, description: String)? {
        guard let name = pair[0]?.stringValue, !name.isEmpty else { return nil }
        return (name.hasPrefix("/") ? name : "/" + name, pair[1]?.stringValue ?? "")
    }

    // MARK: Filtering

    /// Items to show for `query`. Empty: Commands then Skills in catalog order, never-used bundled
    /// skills dropped. Otherwise every match, best score first, then grouped Commands before Skills.
    public static func filter(_ items: [SlashItem], query: String) -> [SlashItem] {
        let normalized = normalize(query)
        guard !normalized.isEmpty else { return items.filter { !$0.isUnusedBundled } }
        var scored: [(index: Int, item: SlashItem, score: Int)] = []
        for (index, item) in items.enumerated() {
            let itemScore: Int = score(item, normalized)
            if itemScore != .max { scored.append((index, item, itemScore)) }
        }
        scored.sort { lhs, rhs in
            lhs.score != rhs.score ? lhs.score < rhs.score : lhs.index < rhs.index
        }
        let ranked: [SlashItem] = scored.map(\.item)
        let commands: [SlashItem] = ranked.filter { $0.group == .commands }
        let skills: [SlashItem] = ranked.filter { $0.group == .skills }
        return commands + skills
    }

    static func normalize(_ query: String) -> String {
        var text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasPrefix("/") { text.removeFirst() }
        return text.lowercased()
    }

    /// Lowercased value followed by its alphanumeric word tokens.
    static func tokens(_ value: String) -> [String] {
        let lowered = value.lowercased()
        let words = lowered.split(whereSeparator: { !($0.isASCII && ($0.isLetter || $0.isNumber)) }).map(String.init)
        return [lowered] + words
    }

    /// Lower wins; `Int.max` is no match. Name tokens score 0...2, description tokens 3...5.
    static func score(_ item: SlashItem, _ query: String) -> Int {
        let name = tokens(String(item.command.dropFirst()))
        return min(score(fields: name, query: query, offset: 0), score(fields: tokens(item.description), query: query, offset: 3))
    }

    private static func score(fields: [String], query: String, offset: Int) -> Int {
        if fields.contains(where: { $0 == query || "/" + $0 == query }) { return offset }
        if fields.contains(where: { $0.hasPrefix(query) || ("/" + $0).hasPrefix(query) }) { return offset + 1 }
        if fields.contains(where: { $0.contains(query) }) { return offset + 2 }
        return .max
    }
}
