import Foundation

enum MarkdownSegment: Sendable, Equatable {
    case text(String)
    case math(String, isComplete: Bool)
    case code(language: String?, body: String)
}

enum MarkdownSegmenter {
    private struct Fence {
        var character: Character
        var length: Int
        var indent: Int
        var language: String?
        var startInPending: Int
    }

    private static let mathSearchLimit = 2_000

    static func segments(in source: String, isStreaming: Bool) -> [MarkdownSegment]? {
        let mayHaveMath = source.contains("$$") || source.contains("\\[")
        guard mayHaveMath || isStreaming else { return nil }
        let normalized = source.unicodeScalars.contains("\r") ? source.replacingOccurrences(of: "\r\n", with: "\n") : source
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)

        var output: [MarkdownSegment] = []
        var pending: [Substring] = []
        var fence: Fence?
        var special = false
        var index = 0

        func flushText() {
            guard !pending.isEmpty else { return }
            output.append(.text(pending.joined(separator: "\n")))
            pending.removeAll(keepingCapacity: true)
        }

        while index < lines.count {
            let line = lines[index]
            if let open = fence {
                pending.append(line)
                if closesFence(line, open) { fence = nil }
                index += 1
                continue
            }
            if let run = fenceRun(line), let opened = openingFence(run, startInPending: pending.count) {
                fence = opened
                pending.append(line)
                index += 1
                continue
            }
            if mayHaveMath, let math = mathBlock(in: lines, at: index, isStreaming: isStreaming) {
                flushText()
                output.append(.math(math.tex, isComplete: math.isComplete))
                special = true
                index += math.consumed
                continue
            }
            pending.append(line)
            index += 1
        }

        if isStreaming, let open = fence {
            let body = pending[(open.startInPending + 1)...].map { stripIndent($0, up: open.indent) }
            pending.removeSubrange(open.startInPending...)
            flushText()
            output.append(.code(language: open.language, body: body.joined(separator: "\n")))
            special = true
        } else {
            flushText()
        }
        return special ? output : nil
    }

    private static func fenceRun(_ line: Substring) -> (character: Character, length: Int, indent: Int, rest: Substring)? {
        var indent = 0
        var cursor = line.startIndex
        while cursor < line.endIndex, line[cursor] == " ", indent < 4 {
            indent += 1
            cursor = line.index(after: cursor)
        }
        guard indent <= 3, cursor < line.endIndex else { return nil }
        let character = line[cursor]
        guard character == "`" || character == "~" else { return nil }
        var length = 0
        while cursor < line.endIndex, line[cursor] == character {
            length += 1
            cursor = line.index(after: cursor)
        }
        guard length >= 3 else { return nil }
        return (character, length, indent, line[cursor...])
    }

    private static func openingFence(
        _ run: (character: Character, length: Int, indent: Int, rest: Substring),
        startInPending: Int
    ) -> Fence? {
        if run.character == "`", run.rest.contains("`") { return nil }
        let language = run.rest.split(whereSeparator: \.isWhitespace).first.map(String.init)
        return Fence(character: run.character, length: run.length, indent: run.indent, language: language, startInPending: startInPending)
    }

    private static func closesFence(_ line: Substring, _ open: Fence) -> Bool {
        guard let run = fenceRun(line), run.character == open.character, run.length >= open.length else { return false }
        return run.rest.allSatisfy(\.isWhitespace)
    }

    private static func stripIndent(_ line: Substring, up limit: Int) -> String {
        var removed = 0
        var cursor = line.startIndex
        while cursor < line.endIndex, line[cursor] == " ", removed < limit {
            removed += 1
            cursor = line.index(after: cursor)
        }
        return String(line[cursor...])
    }

    private struct MathBlock {
        var tex: String
        var isComplete: Bool
        var consumed: Int
    }

    private static func mathBlock(in lines: [Substring], at index: Int, isStreaming: Bool) -> MathBlock? {
        let line = lines[index]
        var indent = 0
        var cursor = line.startIndex
        while cursor < line.endIndex, line[cursor] == " " {
            indent += 1
            cursor = line.index(after: cursor)
        }
        guard indent <= 3 else { return nil }
        let trimmed = line[cursor...].trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("$$") {
            return delimited(lines, at: index, first: String(trimmed.dropFirst(2)), close: "$$", streamsIncomplete: isStreaming)
        }
        if trimmed.hasPrefix("\\[") {
            return delimited(lines, at: index, first: String(trimmed.dropFirst(2)), close: "\\]", streamsIncomplete: false)
        }
        return nil
    }

    private static func delimited(
        _ lines: [Substring],
        at index: Int,
        first: String,
        close: String,
        streamsIncomplete: Bool
    ) -> MathBlock? {
        if let end = first.range(of: close) {
            let tex = String(first[..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let tail = first[end.upperBound...].trimmingCharacters(in: .whitespaces)
            guard tail.isEmpty, !tex.isEmpty else { return nil }
            return MathBlock(tex: tex, isComplete: true, consumed: 1)
        }
        var body = [first]
        var cursor = index + 1
        let limit = min(lines.count, index + 1 + mathSearchLimit)
        while cursor < limit {
            let line = lines[cursor]
            if let run = fenceRun(line), openingFence(run, startInPending: 0) != nil { return nil }
            if let end = line.range(of: close) {
                body.append(String(line[..<end.lowerBound]))
                let tail = line[end.upperBound...].trimmingCharacters(in: .whitespaces)
                let tex = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                guard tail.isEmpty, !tex.isEmpty else { return nil }
                return MathBlock(tex: tex, isComplete: true, consumed: cursor - index + 1)
            }
            body.append(String(line))
            cursor += 1
        }
        guard streamsIncomplete, cursor == lines.count else { return nil }
        let tex = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return MathBlock(tex: tex, isComplete: false, consumed: lines.count - index)
    }
}
