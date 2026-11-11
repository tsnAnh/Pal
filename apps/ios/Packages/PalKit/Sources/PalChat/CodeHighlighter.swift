import Foundation

public enum CodeTokenKind: Sendable {
    case plain
    case keyword
    case string
    case comment
    case number
    case type
    case function
    case attribute
    case punctuation
}

public struct CodeSpan: Sendable, Equatable {
    public var text: String
    public var kind: CodeTokenKind

    public init(text: String, kind: CodeTokenKind) {
        self.text = text
        self.kind = kind
    }
}

public enum CodeHighlighter {
    public static let characterLimit = 40_000

    public static func spans(language: String?, code: String) -> [CodeSpan]? {
        guard let name = RichClassifier.normalize(language), let spec = CodeLanguageSpecs.resolve(name) else { return nil }
        guard code.utf8.count <= characterLimit * 4 else { return nil }
        let scalars = Array(code.unicodeScalars)
        guard scalars.count <= characterLimit else { return nil }
        var scanner = CodeScanner(scalars: scalars, spec: spec)
        return scanner.run()
    }
}

private struct CodeScanner {
    let scalars: [Unicode.Scalar]
    let spec: LanguageSpec
    private var runs: [(kind: CodeTokenKind, start: Int, end: Int)] = []
    private var position = 0

    init(scalars: [Unicode.Scalar], spec: LanguageSpec) {
        self.scalars = scalars
        self.spec = spec
    }

    mutating func run() -> [CodeSpan] {
        if spec.style == .markup { scanMarkup() } else { scanCode() }
        return runs.map { run in
            CodeSpan(text: String(String.UnicodeScalarView(scalars[run.start..<run.end])), kind: run.kind)
        }
    }

    private var count: Int { scalars.count }

    private mutating func emit(_ kind: CodeTokenKind, to end: Int) {
        let target = max(end, position + 1)
        let bounded = min(target, count)
        guard bounded > position else { return }
        if let last = runs.last, last.kind == kind, last.end == position {
            runs[runs.count - 1].end = bounded
        } else {
            runs.append((kind, position, bounded))
        }
        position = bounded
    }

    private func matches(_ pattern: [Unicode.Scalar], at index: Int) -> Bool {
        guard !pattern.isEmpty, index + pattern.count <= count else { return false }
        for offset in pattern.indices where scalars[index + offset] != pattern[offset] { return false }
        return true
    }

    private func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r"
    }

    private func isDigit(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 0x30 && scalar.value <= 0x39
    }

    private func isIdentifierStart(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "_" || scalar.properties.isAlphabetic || (spec.dollarIdentifiers && scalar == "$")
    }

    private func isIdentifierPart(_ scalar: Unicode.Scalar) -> Bool {
        isIdentifierStart(scalar) || isDigit(scalar)
    }

    private func isHexDigit(_ scalar: Unicode.Scalar) -> Bool {
        isDigit(scalar) || (scalar.value >= 0x41 && scalar.value <= 0x46) || (scalar.value >= 0x61 && scalar.value <= 0x66)
    }

    private static let punctuation: Set<Unicode.Scalar> = Set("{}[]()<>;,.:=+-*/%&|^!~?\\".unicodeScalars)

    private mutating func scanCode() {
        while position < count {
            let start = position
            let scalar = scalars[start]
            if isSpace(scalar) {
                var end = start + 1
                while end < count, isSpace(scalars[end]) { end += 1 }
                emit(.plain, to: end)
            } else if let end = commentEnd(at: start) {
                emit(.comment, to: end)
            } else if let end = stringEnd(at: start) {
                let isKeyString = spec.keyTerminator.map { isKey(after: end, terminator: $0, requireSpace: false) } ?? false
                emit(isKeyString ? .attribute : .string, to: end)
            } else if let end = numberEnd(at: start) {
                emit(.number, to: end)
            } else if let end = variableEnd(at: start) {
                emit(.attribute, to: end)
            } else if let end = attributeEnd(at: start) {
                emit(.attribute, to: end)
            } else if isIdentifierStart(scalar) {
                scanIdentifier(from: start)
            } else if Self.punctuation.contains(scalar) {
                emit(.punctuation, to: start + 1)
            } else {
                emit(.plain, to: start + 1)
            }
        }
    }

    private func commentEnd(at index: Int) -> Int? {
        for prefix in spec.lineComments where matches(prefix, at: index) {
            if prefix.count == 1, prefix[0] == "#", spec.shellVariables, index > 0, !isSpace(scalars[index - 1]) { continue }
            var end = index + prefix.count
            while end < count, scalars[end] != "\n", scalars[end] != "\r" { end += 1 }
            return end
        }
        guard let block = spec.blockComment, matches(block.open, at: index) else { return nil }
        var end = index + block.open.count
        while end < count, !matches(block.close, at: end) { end += 1 }
        return end < count ? end + block.close.count : count
    }

    private func stringEnd(at index: Int) -> Int? {
        for rule in spec.quotes where matches(rule.open, at: index) {
            var end = index + rule.open.count
            while end < count {
                let scalar = scalars[end]
                if rule.escapes, scalar == "\\" {
                    end = min(end + 2, count)
                    continue
                }
                if matches(rule.close, at: end) { return end + rule.close.count }
                if !rule.multiline, scalar == "\n" { return end }
                end += 1
            }
            return count
        }
        return nil
    }

    private func isKey(after index: Int, terminator: Unicode.Scalar, requireSpace: Bool) -> Bool {
        var cursor = index
        while cursor < count, scalars[cursor] == " " || scalars[cursor] == "\t" { cursor += 1 }
        guard cursor < count, scalars[cursor] == terminator else { return false }
        guard requireSpace else { return true }
        let after = cursor + 1
        return after >= count || isSpace(scalars[after])
    }

    private func numberEnd(at index: Int) -> Int? {
        let scalar = scalars[index]
        if spec.colorLiterals, scalar == "#", index + 1 < count, isHexDigit(scalars[index + 1]) {
            var end = index + 1
            while end < count, isHexDigit(scalars[end]) { end += 1 }
            return end
        }
        let leadingDot = scalar == "." && index + 1 < count && isDigit(scalars[index + 1])
            && !(index > 0 && isIdentifierPart(scalars[index - 1]))
        guard isDigit(scalar) || leadingDot else { return nil }
        let hex = scalar == "0" && index + 1 < count && (scalars[index + 1] == "x" || scalars[index + 1] == "X")
        var end = index + 1
        while end < count {
            let current = scalars[end]
            if current == "_" || current.properties.isAlphabetic || isDigit(current) {
                let isExponent = !hex && (current == "e" || current == "E")
                if isExponent, end + 2 < count, scalars[end + 1] == "+" || scalars[end + 1] == "-", isDigit(scalars[end + 2]) {
                    end += 2
                }
                end += 1
            } else if current == ".", end + 1 < count, isDigit(scalars[end + 1]) {
                end += 1
            } else {
                break
            }
        }
        return end
    }

    private func variableEnd(at index: Int) -> Int? {
        guard spec.shellVariables, scalars[index] == "$", index + 1 < count else { return nil }
        let next = scalars[index + 1]
        if next == "{" {
            var end = index + 2
            while end < count, scalars[end] != "}", scalars[end] != "\n" { end += 1 }
            return end < count && scalars[end] == "}" ? end + 1 : end
        }
        if isIdentifierStart(next) {
            var end = index + 2
            while end < count, isIdentifierPart(scalars[end]) { end += 1 }
            return end
        }
        if isDigit(next) || "#?@!*$-".unicodeScalars.contains(next) { return index + 2 }
        return nil
    }

    private func attributeEnd(at index: Int) -> Int? {
        guard spec.attributePrefixes.contains(scalars[index]), index + 1 < count, isIdentifierStart(scalars[index + 1]) else { return nil }
        var end = index + 2
        while end < count, isIdentifierPart(scalars[end]) { end += 1 }
        return end
    }

    private mutating func scanIdentifier(from start: Int) {
        var end = start + 1
        while end < count {
            if isIdentifierPart(scalars[end]) {
                end += 1
            } else if spec.hyphenIdentifiers, scalars[end] == "-", end + 1 < count, isIdentifierPart(scalars[end + 1]) {
                end += 1
            } else {
                break
            }
        }
        emit(classify(start: start, end: end), to: end)
    }

    private func classify(start: Int, end: Int) -> CodeTokenKind {
        if let terminator = spec.keyTerminator, isKey(after: end, terminator: terminator, requireSpace: terminator == ":") { return .attribute }
        let word = String(String.UnicodeScalarView(scalars[start..<end]))
        if spec.keywords.contains(spec.caseInsensitiveKeywords ? word.lowercased() : word) { return .keyword }
        if spec.capitalizedTypes, isTypeName(start: start, end: end) { return .type }
        if spec.functionCalls, end < count, scalars[end] == "(" { return .function }
        return .plain
    }

    private func isTypeName(start: Int, end: Int) -> Bool {
        guard end - start >= 2, scalars[start].properties.isUppercase else { return false }
        return scalars[start..<end].contains { $0.properties.isLowercase }
    }

    private mutating func scanMarkup() {
        while position < count {
            let start = position
            if matches(Array("<!--".unicodeScalars), at: start) {
                var end = start + 4
                let close = Array("-->".unicodeScalars)
                while end < count, !matches(close, at: end) { end += 1 }
                emit(.comment, to: end < count ? end + 3 : count)
            } else if scalars[start] == "<", start + 1 < count, isTagStart(scalars[start + 1]) {
                scanTag(from: start)
            } else {
                var end = start + 1
                while end < count, scalars[end] != "<" { end += 1 }
                emit(.plain, to: end)
            }
        }
    }

    private func isTagStart(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isAlphabetic || scalar == "/" || scalar == "!" || scalar == "?"
    }

    private mutating func scanTag(from start: Int) {
        var cursor = start + 1
        if cursor < count, scalars[cursor] == "/" || scalars[cursor] == "!" || scalars[cursor] == "?" { cursor += 1 }
        emit(.punctuation, to: cursor)
        let nameStart = cursor
        while cursor < count, isIdentifierPart(scalars[cursor]) || scalars[cursor] == "-" || scalars[cursor] == ":" || scalars[cursor] == "." {
            cursor += 1
        }
        if cursor > nameStart { emit(.keyword, to: cursor) }
        while position < count {
            let scalar = scalars[position]
            if scalar == ">" {
                emit(.punctuation, to: position + 1)
                return
            }
            if isSpace(scalar) {
                var end = position + 1
                while end < count, isSpace(scalars[end]) { end += 1 }
                emit(.plain, to: end)
            } else if scalar == "\"" || scalar == "'" {
                var end = position + 1
                while end < count, scalars[end] != scalar { end += 1 }
                emit(.string, to: min(end + 1, count))
            } else if scalar == "=" || scalar == "/" || scalar == "?" {
                emit(.punctuation, to: position + 1)
            } else if scalar == "<" {
                return
            } else {
                var end = position + 1
                while end < count, !isSpace(scalars[end]), !"=/>\"'<".unicodeScalars.contains(scalars[end]) { end += 1 }
                emit(afterEquals() ? .string : .attribute, to: end)
            }
        }
    }

    private func afterEquals() -> Bool {
        var cursor = position - 1
        while cursor >= 0, isSpace(scalars[cursor]) { cursor -= 1 }
        return cursor >= 0 && scalars[cursor] == "="
    }
}
