import Foundation

public struct SkillEnvRequirement: Sendable, Equatable, Identifiable {
    public var name: String
    public var prompt: String?
    public var help: String?
    public var isOptional: Bool

    public var id: String { name }

    public init(name: String, prompt: String? = nil, help: String? = nil, isOptional: Bool = false) {
        self.name = name
        self.prompt = prompt
        self.help = help
        self.isOptional = isOptional
    }
}

public struct SkillRequirements: Sendable, Equatable {
    public var environment: [SkillEnvRequirement]
    public var commands: [String]

    public init(environment: [SkillEnvRequirement] = [], commands: [String] = []) {
        self.environment = environment
        self.commands = commands
    }

    public var isEmpty: Bool { environment.isEmpty && commands.isEmpty }

    public var needsSecrets: Bool { environment.contains { !$0.isOptional } }
}

extension SkillRequirements {
    private struct Line {
        let indent: Int
        let text: String
    }

    private struct Section {
        let inline: String
        let body: [Line]
    }

    private static let textLimit = 400

    public static func parse(skillMarkdown text: String) -> SkillRequirements {
        let lines = frontmatter(text)
        var environment: [SkillEnvRequirement] = []
        var commands: [String] = []
        if let block = section("required_environment_variables", in: lines, indent: 0) {
            environment += environmentItems(block)
        }
        if let block = section("required_commands", in: lines, indent: 0) {
            commands += scalars(block)
        }
        if let block = section("prerequisites", in: lines, indent: 0) {
            let base = block.body.map(\.indent).min() ?? 0
            if let names = section("env_vars", in: block.body, indent: base) {
                environment += scalars(names).map { SkillEnvRequirement(name: $0) }
            }
            if let names = section("commands", in: block.body, indent: base) {
                commands += scalars(names)
            }
        }
        var seenEnvironment = Set<String>()
        var seenCommands = Set<String>()
        return SkillRequirements(
            environment: environment.filter { isEnvironmentName($0.name) && seenEnvironment.insert($0.name).inserted },
            commands: commands.filter { !$0.isEmpty && $0.count <= 64 && seenCommands.insert($0).inserted }
        )
    }

    private static func frontmatter(_ text: String) -> [Line] {
        var body = Substring(text)
        if body.first == "\u{FEFF}" { body = body.dropFirst() }
        var lines: [Line] = []
        var started = false
        for raw in body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !started {
                if trimmed.isEmpty { continue }
                guard trimmed == "---" else { return [] }
                started = true
                continue
            }
            if trimmed == "---" || trimmed == "..." { break }
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            lines.append(Line(indent: line.prefix { $0 == " " || $0 == "\t" }.count, text: trimmed))
        }
        return lines
    }

    private static func isListItem(_ text: String) -> Bool { text == "-" || text.hasPrefix("- ") }

    private static func section(_ key: String, in lines: [Line], indent: Int) -> Section? {
        guard let start = lines.firstIndex(where: { $0.indent == indent && $0.text.hasPrefix(key + ":") }) else { return nil }
        let inline = String(lines[start].text.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
        let body = lines[(start + 1)...].prefix { $0.indent > indent || ($0.indent == indent && isListItem($0.text)) }
        return Section(inline: inline, body: Array(body))
    }

    private static func scalar(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespaces)
        if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
            value = String(value.dropFirst().dropLast())
        }
        return String(value.prefix(textLimit))
    }

    private static func inlineList(_ raw: String) -> [String] {
        var value = raw
        if value.hasPrefix("[") { value.removeFirst() }
        if value.hasSuffix("]") { value.removeLast() }
        return value.split(separator: ",").map { scalar(String($0)) }.filter { !$0.isEmpty }
    }

    private static func scalars(_ block: Section) -> [String] {
        if !block.inline.isEmpty { return inlineList(block.inline) }
        return block.body.compactMap { line in
            guard isListItem(line.text) else { return nil }
            let value = scalar(String(line.text.dropFirst()))
            return value.isEmpty ? nil : value
        }
    }

    private static func keyValue(_ text: String) -> (key: String, value: String)? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let key = text[..<colon].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0 == "_" }) else { return nil }
        return (key, scalar(String(text[text.index(after: colon)...])))
    }

    private static func environmentItems(_ block: Section) -> [SkillEnvRequirement] {
        if !block.inline.isEmpty { return inlineList(block.inline).map { SkillEnvRequirement(name: $0) } }
        guard let dashIndent = block.body.filter({ isListItem($0.text) }).map(\.indent).min() else { return [] }
        var items: [[String]] = []
        for line in block.body {
            if line.indent == dashIndent, isListItem(line.text) {
                items.append([String(line.text.dropFirst()).trimmingCharacters(in: .whitespaces)])
            } else if !items.isEmpty {
                items[items.count - 1].append(line.text)
            }
        }
        return items.compactMap { texts in
            var fields: [String: String] = [:]
            for text in texts where !text.isEmpty {
                if let pair = keyValue(text) { fields[pair.key] = pair.value } else if fields["name"] == nil { fields["name"] = scalar(text) }
            }
            guard let name = fields["name"] else { return nil }
            let optional = fields["optional"]?.lowercased()
            return SkillEnvRequirement(
                name: name,
                prompt: fields["prompt"].flatMap { $0.isEmpty ? nil : $0 },
                help: fields["help"].flatMap { $0.isEmpty ? nil : $0 },
                isOptional: optional == "true" || optional == "yes"
            )
        }
    }

    private static func isEnvironmentName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, first == "_" || (first.isASCII && CharacterSet.letters.contains(first)) else { return false }
        return name.count <= 128 && name.unicodeScalars.allSatisfy { $0 == "_" || ($0.isASCII && CharacterSet.alphanumerics.contains($0)) }
    }
}
