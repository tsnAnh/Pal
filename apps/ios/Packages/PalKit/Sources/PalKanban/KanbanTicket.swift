import Foundation

enum KanbanTicket {
    private static let labelNames: [String: KanbanBodyLabel] = [
        "goal": .goal,
        "done means": .doneMeans, "done when": .doneMeans,
        "current status": .currentStatus, "status": .currentStatus,
        "owner decisions": .ownerDecisions,
        "pull requests": .pullRequests, "pull request": .pullRequests,
    ]

    static func splitFooter(_ lines: [String]) -> (ticket: [String], footer: [String]) {
        let marker = lines.firstIndex(where: KanbanBody.isFooterMarker)
        var ticket: [String] = []
        var footer: [String] = []
        var inFence = false
        for line in lines[..<(marker ?? lines.endIndex)] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                inFence.toggle()
                ticket.append(line)
            } else if !inFence, KanbanBody.isMachineLine(trimmed) || trimmed.hasPrefix("Sessions:") {
                footer.append(trimmed)
            } else {
                ticket.append(line)
            }
        }
        if let marker {
            footer += lines[(marker + 1)...]
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        return (ticket, footer)
    }

    static func sections(_ lines: [String], title: String?) -> (intro: [String], byLabel: [KanbanBodyLabel: [String]]) {
        var preamble: [String] = []
        var sections: [KanbanBodyLabel: [String]] = [:]
        var current: KanbanBodyLabel?
        var inFence = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isFence = trimmed.hasPrefix("```")
            if isFence { inFence.toggle() }
            if !isFence, !inFence, let found = labelLine(trimmed) {
                current = found.label
                var content = sections[found.label].map { $0 + [""] } ?? []
                if !found.inline.isEmpty { content.append(found.inline) }
                sections[found.label] = content
            } else if let current {
                sections[current, default: []].append(line)
            } else {
                preamble.append(line)
            }
        }
        return (trimmedPreamble(preamble, title: title), sections)
    }

    static func blocks(_ lines: [String]) -> [KanbanBodyBlock] {
        var reader = KanbanBody.Reader()
        for line in lines { reader.read(line) }
        return reader.finish()
    }

    static func part(_ label: KanbanBodyLabel, lines: [String]) -> KanbanBodyPart? {
        let links = label == .pullRequests ? webLinks(in: lines.joined(separator: "\n")) : []
        let shown = links.isEmpty ? blocks(lines) : []
        guard !shown.isEmpty || !links.isEmpty else { return nil }
        return KanbanBodyPart(label: label, blocks: shown, links: links)
    }

    private static func labelLine(_ trimmed: String) -> (label: KanbanBodyLabel, inline: String)? {
        let heading = stripHeading(Substring(trimmed))
        let rest = stripListMarker(heading.text)
        let split: (name: Substring, after: Substring)?
        if rest.hasPrefix("**") || rest.hasPrefix("__") {
            split = splitBold(rest)
        } else if let colon = rest.firstIndex(of: ":") {
            split = (rest[..<colon], rest[rest.index(after: colon)...])
        } else if heading.isHeading {
            split = (rest, Substring(""))
        } else {
            split = nil
        }
        guard let split, let label = labelNames[split.name.trimmingCharacters(in: .whitespaces).lowercased()] else { return nil }
        return (label, split.after.trimmingCharacters(in: .whitespaces))
    }

    private static func stripHeading(_ text: Substring) -> (text: Substring, isHeading: Bool) {
        let hashes = text.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), text.dropFirst(hashes).first == " " else { return (text, false) }
        return (text.dropFirst(hashes).drop { $0 == " " }, true)
    }

    static func stripListMarker(_ text: Substring) -> Substring {
        guard let marker = text.first, "-*+".contains(marker), text.dropFirst().first == " " else { return text }
        return text.dropFirst().drop { $0 == " " }
    }

    private static func splitBold(_ text: Substring) -> (name: Substring, after: Substring)? {
        let mark = String(text.prefix(2))
        let inner = text.dropFirst(2)
        guard let close = inner.range(of: mark) else { return nil }
        var name = inner[..<close.lowerBound]
        var after = inner[close.upperBound...]
        var hasColon = name.hasSuffix(":")
        if hasColon { name = name.dropLast() }
        let tail = after.drop { $0 == " " }
        if tail.first == ":" {
            hasColon = true
            after = tail.dropFirst()
        }
        guard hasColon || tail.isEmpty else { return nil }
        return (name, after)
    }

    private static func trimmedPreamble(_ lines: [String], title: String?) -> [String] {
        var rest = dropLeadingBlanks(ArraySlice(lines))
        if let first = rest.first, isTitleLine(first, title: title) { rest = rest.dropFirst() }
        return Array(dropLeadingBlanks(rest))
    }

    private static func dropLeadingBlanks(_ lines: ArraySlice<String>) -> ArraySlice<String> {
        lines.drop { $0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private static func isTitleLine(_ line: String, title: String?) -> Bool {
        guard let title else { return false }
        let wanted = comparable(title)
        return !wanted.isEmpty && comparable(line) == wanted
    }

    private static func comparable(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespaces)
            .drop { $0 == "#" }
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
    }

    private static func webLinks(in text: String) -> [URL] {
        guard let regex = try? NSRegularExpression(pattern: #"https?://[^\s<>"`*]+"#) else { return [] }
        var seen: Set<String> = []
        var urls: [URL] = []
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            let raw = text[range].trimmingCharacters(in: CharacterSet(charactersIn: ".,;)]>"))
            if let url = URL(string: raw), seen.insert(url.absoluteString).inserted { urls.append(url) }
        }
        return urls
    }
}
