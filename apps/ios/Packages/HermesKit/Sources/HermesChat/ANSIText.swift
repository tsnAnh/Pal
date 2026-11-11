import Foundation

public enum ANSIColor: Sendable, Equatable {
    case standard(Int)
    case bright(Int)
    case indexed(Int)
    case rgb(Int, Int, Int)
}

public struct ANSISegment: Sendable, Equatable {
    public var text: String
    public var foreground: ANSIColor?
    public var background: ANSIColor?
    public var bold: Bool
    public var dim: Bool
    public var italic: Bool
    public var underline: Bool

    public init(
        text: String,
        foreground: ANSIColor? = nil,
        background: ANSIColor? = nil,
        bold: Bool = false,
        dim: Bool = false,
        italic: Bool = false,
        underline: Bool = false
    ) {
        self.text = text
        self.foreground = foreground
        self.background = background
        self.bold = bold
        self.dim = dim
        self.italic = italic
        self.underline = underline
    }
}

public enum ANSIParser {
    public static func containsEscapes(_ source: String) -> Bool {
        source.utf8.contains(0x1B)
    }

    public static func parse(_ source: String) -> [ANSISegment] {
        var machine = ANSIMachine()
        machine.run(Array(source.unicodeScalars))
        return machine.finish()
    }

    public static func stripped(_ source: String) -> String {
        parse(source).map(\.text).joined()
    }
}

private struct ANSIStyle: Equatable {
    var foreground: ANSIColor?
    var background: ANSIColor?
    var bold = false
    var dim = false
    var italic = false
    var underline = false
}

private struct ANSIMachine {
    private static let oscLimit = 4_096

    private var style = ANSIStyle()
    private var finished: [ANSISegment] = []
    private var line: [ANSISegment] = []
    private var buffer = String.UnicodeScalarView()
    private var carriageReturnPending = false

    mutating func run(_ scalars: [Unicode.Scalar]) {
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            switch scalar.value {
            case 0x1B:
                index = skipEscape(scalars, at: index)
                continue
            case 0x0D:
                if index + 1 < scalars.count, scalars[index + 1].value == 0x0A {
                    index += 1
                    continue
                }
                carriageReturnPending = true
            case 0x0A:
                endLine()
            case 0x00, 0x07, 0x9B:
                break
            default:
                if carriageReturnPending {
                    line.removeAll(keepingCapacity: true)
                    buffer = String.UnicodeScalarView()
                    carriageReturnPending = false
                }
                buffer.append(scalar)
            }
            index += 1
        }
    }

    mutating func finish() -> [ANSISegment] {
        commitBuffer()
        flushLine()
        return finished
    }

    private mutating func endLine() {
        buffer.append("\n")
        commitBuffer()
        flushLine()
        carriageReturnPending = false
    }

    private mutating func commitBuffer() {
        guard !buffer.isEmpty else { return }
        Self.merge(
            ANSISegment(
                text: String(buffer),
                foreground: style.foreground,
                background: style.background,
                bold: style.bold,
                dim: style.dim,
                italic: style.italic,
                underline: style.underline
            ),
            into: &line
        )
        buffer = String.UnicodeScalarView()
    }

    private mutating func flushLine() {
        for segment in line { Self.merge(segment, into: &finished) }
        line.removeAll(keepingCapacity: true)
    }

    private mutating func setStyle(_ next: ANSIStyle) {
        guard next != style else { return }
        commitBuffer()
        style = next
    }

    private static func merge(_ segment: ANSISegment, into target: inout [ANSISegment]) {
        if let last = target.last,
           last.foreground == segment.foreground, last.background == segment.background,
           last.bold == segment.bold, last.dim == segment.dim,
           last.italic == segment.italic, last.underline == segment.underline {
            target[target.count - 1].text += segment.text
        } else {
            target.append(segment)
        }
    }

    private mutating func skipEscape(_ scalars: [Unicode.Scalar], at start: Int) -> Int {
        let count = scalars.count
        let next = start + 1
        guard next < count else { return count }
        switch scalars[next].value {
        case 0x5B:
            return skipCSI(scalars, parametersStart: next + 1)
        case 0x5D, 0x50, 0x58, 0x5E, 0x5F:
            let limit = min(count, next + 1 + Self.oscLimit)
            var cursor = next + 1
            while cursor < limit {
                let value = scalars[cursor].value
                if value == 0x07 { return cursor + 1 }
                if value == 0x1B, cursor + 1 < count, scalars[cursor + 1].value == 0x5C { return cursor + 2 }
                cursor += 1
            }
            return limit == count ? count : next + 1
        case 0x20...0x2F:
            var cursor = next
            while cursor < count, (0x20...0x2F).contains(scalars[cursor].value) { cursor += 1 }
            guard cursor < count else { return count }
            return (0x30...0x7E).contains(scalars[cursor].value) ? cursor + 1 : cursor
        case 0x30...0x7E:
            return next + 1
        default:
            return next
        }
    }

    private mutating func skipCSI(_ scalars: [Unicode.Scalar], parametersStart: Int) -> Int {
        let count = scalars.count
        var cursor = parametersStart
        while cursor < count, (0x30...0x3F).contains(scalars[cursor].value) { cursor += 1 }
        let parameters = scalars[parametersStart..<cursor]
        let intermediatesStart = cursor
        while cursor < count, (0x20...0x2F).contains(scalars[cursor].value) { cursor += 1 }
        guard cursor < count else { return count }
        let final = scalars[cursor].value
        guard (0x40...0x7E).contains(final) else { return cursor }
        let isPlainSGR = final == 0x6D && cursor == intermediatesStart
            && !(parameters.first.map { (0x3C...0x3F).contains($0.value) } ?? false)
        if isPlainSGR { applySGR(parameters) }
        return cursor + 1
    }

    private mutating func applySGR(_ parameters: ArraySlice<Unicode.Scalar>) {
        let tokens = Self.tokens(parameters)
        var next = style
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            let code = token[0] ?? 0
            switch code {
            case 0: next = ANSIStyle()
            case 1: next.bold = true
            case 2: next.dim = true
            case 3: next.italic = true
            case 4: next.underline = true
            case 22:
                next.bold = false
                next.dim = false
            case 23: next.italic = false
            case 24: next.underline = false
            case 30...37: next.foreground = .standard(code - 30)
            case 39: next.foreground = nil
            case 40...47: next.background = .standard(code - 40)
            case 49: next.background = nil
            case 90...97: next.foreground = .bright(code - 90)
            case 100...107: next.background = .bright(code - 100)
            case 38, 48:
                let (color, consumed) = Self.extendedColor(tokens, at: index)
                if code == 38 { next.foreground = color } else { next.background = color }
                index += consumed
            default: break
            }
            index += 1
        }
        setStyle(next)
    }

    private static func extendedColor(_ tokens: [[Int?]], at index: Int) -> (ANSIColor?, Int) {
        let token = tokens[index]
        if token.count > 1 {
            if token[1] == 5, token.count > 2 { return (.indexed(clamp(token[2])), 0) }
            if token[1] == 2, token.count >= 5 {
                let tail = token.suffix(3)
                let values = tail.map(clamp)
                return (.rgb(values[0], values[1], values[2]), 0)
            }
            return (nil, 0)
        }
        let remaining = tokens.count - index - 1
        guard remaining > 0 else { return (nil, 0) }
        let mode = tokens[index + 1][0] ?? 0
        if mode == 5 {
            guard remaining >= 2 else { return (nil, remaining) }
            return (.indexed(clamp(tokens[index + 2][0])), 2)
        }
        if mode == 2 {
            guard remaining >= 4 else { return (nil, remaining) }
            let values = (2...4).map { clamp(tokens[index + $0][0]) }
            return (.rgb(values[0], values[1], values[2]), 4)
        }
        return (nil, 1)
    }

    private static func clamp(_ value: Int?) -> Int {
        max(0, min(255, value ?? 0))
    }

    private static func tokens(_ parameters: ArraySlice<Unicode.Scalar>) -> [[Int?]] {
        var tokens: [[Int?]] = []
        var parts: [Int?] = []
        var current: Int?
        for scalar in parameters {
            switch scalar.value {
            case 0x30...0x39:
                current = min((current ?? 0) * 10 + Int(scalar.value - 0x30), 100_000)
            case 0x3A:
                parts.append(current)
                current = nil
            case 0x3B:
                parts.append(current)
                tokens.append(parts)
                parts = []
                current = nil
            default:
                break
            }
        }
        parts.append(current)
        tokens.append(parts)
        return tokens
    }
}
