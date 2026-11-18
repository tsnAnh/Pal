import Foundation

public enum KanbanBodyBlock: Sendable, Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullets([String])
    case numbered([String])
    case code(String)
}

public enum KanbanBodyLabel: String, Sendable, CaseIterable {
    case goal
    case doneMeans
    case currentStatus
    case ownerDecisions
    case pullRequests

    public var title: String {
        switch self {
        case .goal: String(localized: "Goal")
        case .doneMeans: String(localized: "Done means")
        case .currentStatus: String(localized: "Current status")
        case .ownerDecisions: String(localized: "Owner decisions")
        case .pullRequests: String(localized: "Pull requests")
        }
    }

    public var identifier: String {
        switch self {
        case .goal: "goal"
        case .doneMeans: "done-means"
        case .currentStatus: "current-status"
        case .ownerDecisions: "owner-decisions"
        case .pullRequests: "pull-requests"
        }
    }
}

public struct KanbanBodyPart: Sendable, Equatable, Identifiable {
    public let label: KanbanBodyLabel
    public let blocks: [KanbanBodyBlock]
    public let links: [URL]

    public var id: KanbanBodyLabel { label }

    public init(label: KanbanBodyLabel, blocks: [KanbanBodyBlock], links: [URL] = []) {
        self.label = label
        self.blocks = blocks
        self.links = links
    }
}

public struct KanbanBodyDocument: Sendable, Equatable {
    public let intro: [KanbanBodyBlock]
    public let parts: [KanbanBodyPart]
    public let footer: [String]
    public let ref: String?

    public var isEmpty: Bool { intro.isEmpty && parts.isEmpty }

    public init(intro: [KanbanBodyBlock] = [], parts: [KanbanBodyPart], footer: [String] = [], ref: String? = nil) {
        self.intro = intro
        self.parts = parts
        self.footer = footer
        self.ref = ref
    }
}

public enum KanbanBody {
    private static let machineKeys: Set<String> = [
        "Key", "Kind", "Project", "Bot", "Outcome", "State", "Added", "Updated", "History",
    ]

    public static func parse(_ text: String?, title: String? = nil) -> KanbanBodyDocument {
        let lines = (text ?? "").split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        let split = KanbanTicket.splitFooter(lines)
        let sections = KanbanTicket.sections(split.ticket, title: title)
        let parts = KanbanBodyLabel.allCases.compactMap { label in sections.byLabel[label].flatMap { KanbanTicket.part(label, lines: $0) } }
        return KanbanBodyDocument(intro: KanbanTicket.blocks(sections.intro), parts: parts, footer: split.footer, ref: ref(in: text))
    }

    public static func ref(in body: String?) -> String? {
        for line in (body ?? "").split(whereSeparator: \.isNewline).reversed() {
            if let value = refValue(line) { return value }
        }
        return nil
    }

    public static func title(of body: String?, fallback: String) -> String {
        for line in (body ?? "").split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("```") || isMachineLine(trimmed) { continue }
            let text = trimmed.drop { $0 == "#" }
                .replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "`", with: "")
                .trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { return text }
        }
        return fallback
    }

    static func isMachineLine(_ trimmed: String) -> Bool {
        var rest = Substring(trimmed)
        if rest.hasPrefix("- ") || rest.hasPrefix("* ") { rest = rest.suffix(from: rest.index(rest.startIndex, offsetBy: 2)) }
        guard let colon = rest.firstIndex(of: ":") else { return false }
        let key = rest[..<colon].trimmingCharacters(in: CharacterSet(charactersIn: "*_` "))
        return machineKeys.contains(key)
    }

    static func isFooterMarker<S: StringProtocol>(_ line: S) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("----") && trimmed.lowercased().contains("machine fields")
    }

    private static func refValue(_ line: Substring) -> String? {
        var rest = KanbanTicket.stripListMarker(Substring(line.trimmingCharacters(in: .whitespaces)))
        if rest.hasPrefix("**") { rest = rest.dropFirst(2) }
        guard rest.hasPrefix("Ref:") else { return nil }
        rest = rest.dropFirst(4)
        if rest.hasPrefix("**") { rest = rest.dropFirst(2) }
        guard rest.first == " " else { return nil }
        let value = rest.trimmingCharacters(in: .whitespaces)
        return KanbanRef.isRef(value) ? value.uppercased() : nil
    }

    struct Reader {
        enum Items {
            case none
            case bullets([String])
            case numbered([String])
        }

        var blocks: [KanbanBodyBlock] = []
        var paragraph: [String] = []
        var items: Items = .none
        var fence: [String]?

        mutating func read(_ line: String) {
            if fence != nil {
                readFenced(line)
                return
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                flush()
                fence = []
            } else if trimmed.isEmpty {
                flush()
            } else if let heading = Self.heading(trimmed) {
                flush()
                blocks.append(heading)
            } else if let bullet = Self.bullet(trimmed) {
                startItems(bullet: true)
                append(item: bullet)
            } else if let number = Self.number(trimmed) {
                startItems(bullet: false)
                append(item: number)
            } else if case .none = items {
                paragraph.append(trimmed)
            } else if line.first == " " || line.first == "\t" {
                continueLastItem(trimmed)
            } else {
                flush()
                paragraph.append(trimmed)
            }
        }

        mutating func finish() -> [KanbanBodyBlock] {
            if let fence {
                blocks.append(.code(fence.joined(separator: "\n")))
                self.fence = nil
            }
            flush()
            return blocks
        }

        private mutating func readFenced(_ line: String) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                blocks.append(.code((fence ?? []).joined(separator: "\n")))
                fence = nil
            } else {
                fence?.append(line)
            }
        }

        private mutating func flush() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: " ")))
                paragraph = []
            }
            switch items {
            case .none: break
            case .bullets(let list): blocks.append(.bullets(list))
            case .numbered(let list): blocks.append(.numbered(list))
            }
            items = .none
        }

        private mutating func startItems(bullet: Bool) {
            switch (items, bullet) {
            case (.bullets, true), (.numbered, false): return
            default: flush()
            }
            items = bullet ? .bullets([]) : .numbered([])
        }

        private mutating func append(item: String) {
            switch items {
            case .none: break
            case .bullets(let list): items = .bullets(list + [item])
            case .numbered(let list): items = .numbered(list + [item])
            }
        }

        private mutating func continueLastItem(_ text: String) {
            switch items {
            case .none: break
            case .bullets(var list):
                if let last = list.popLast() { items = .bullets(list + [last + " " + text]) }
            case .numbered(var list):
                if let last = list.popLast() { items = .numbered(list + [last + " " + text]) }
            }
        }

        private static func heading(_ line: String) -> KanbanBodyBlock? {
            let hashes = line.prefix { $0 == "#" }.count
            guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
            return .heading(level: hashes, text: line.dropFirst(hashes).trimmingCharacters(in: .whitespaces))
        }

        private static func bullet(_ line: String) -> String? {
            guard let marker = line.first, "-*+".contains(marker), line.dropFirst().first == " " else { return nil }
            return line.dropFirst(2).trimmingCharacters(in: .whitespaces)
        }

        private static func number(_ line: String) -> String? {
            let digits = line.prefix { $0.isNumber }
            guard !digits.isEmpty, digits.count <= 3 else { return nil }
            let rest = line.dropFirst(digits.count)
            guard let mark = rest.first, mark == "." || mark == ")", rest.dropFirst().first == " " else { return nil }
            return rest.dropFirst(2).trimmingCharacters(in: .whitespaces)
        }
    }
}
