import Foundation
import PalDiagnostics

enum MarkdownChunker {
    private static let space = UInt8(ascii: " ")
    private static let tab = UInt8(ascii: "\t")
    private static let newline = UInt8(ascii: "\n")
    private static let backtick = UInt8(ascii: "`")
    private static let tilde = UInt8(ascii: "~")
    private static let pipe = UInt8(ascii: "|")
    private static let angle = UInt8(ascii: "<")
    private static let quote = UInt8(ascii: ">")

    private struct Fence {
        var character: UInt8
        var length: Int
    }

    static func groups(in source: String) -> [String]? {
        var text = source
        return text.withUTF8 { bytes in
            guard let ranges = ranges(in: bytes) else { return nil }
            let groups = ranges.compactMap { String(bytes: bytes[$0], encoding: .utf8) }
            return groups.count == ranges.count ? groups : nil
        }
    }

    private struct Scan {
        var cuts: [Range<Int>] = []
        var fence: Fence?
        var groupStart: Int?
        var chunkEnd = 0
        var chunkOpen = false
        var chunkSimple = true

        mutating func consume(_ line: Slice<UnsafeBufferPointer<UInt8>>) -> Bool {
            if let open = fence {
                if closes(line, open) { fence = nil }
                chunkOpen = true
                chunkEnd = line.endIndex
                return true
            }
            if line.isEmpty {
                endChunk()
                return true
            }
            if groupStart == nil { groupStart = line.startIndex }
            chunkOpen = true
            chunkEnd = line.endIndex
            guard let verdict = classify(line) else { return false }
            switch verdict {
            case .plain(let simple):
                chunkSimple = chunkSimple && simple
            case .fence(let opened, let simple):
                fence = opened
                chunkSimple = chunkSimple && simple
            }
            return true
        }

        private mutating func endChunk() {
            if chunkOpen, let start = groupStart, chunkSimple {
                cuts.append(start..<chunkEnd)
                groupStart = nil
            }
            chunkOpen = false
            chunkSimple = true
        }
    }

    private static func ranges(in bytes: UnsafeBufferPointer<UInt8>) -> [Range<Int>]? {
        var scan = Scan()
        var lineStart = 0
        while lineStart < bytes.count {
            let lineEnd = bytes[lineStart...].firstIndex(of: newline) ?? bytes.count
            guard scan.consume(bytes[lineStart..<lineEnd]) else { return nil }
            lineStart = lineEnd + 1
        }
        if scan.groupStart == nil, let last = scan.cuts.popLast() { scan.groupStart = last.lowerBound }
        guard let tailStart = scan.groupStart else { return nil }
        return scan.cuts + [tailStart..<bytes.count]
    }

    private enum Verdict {
        case plain(simple: Bool)
        case fence(Fence, simple: Bool)
    }

    private static func classify(_ line: Slice<UnsafeBufferPointer<UInt8>>) -> Verdict? {
        let first = line[line.startIndex]
        let leadingBlank = first == space || first == tab
        guard let firstInk = line.first(where: { $0 != space && $0 != tab }) else { return .plain(simple: false) }
        if firstInk == angle { return nil }
        if !leadingBlank, first == backtick || first == tilde {
            let run = line.prefix(while: { $0 == first }).count
            if run >= 3 { return openingFence(line, character: first, length: run) }
        }
        if hasFenceMarker(line) { return nil }
        if leadingBlank || first == quote || line.contains(pipe) { return .plain(simple: false) }
        return .plain(simple: !startsList(line))
    }

    private static func openingFence(_ line: Slice<UnsafeBufferPointer<UInt8>>, character: UInt8, length: Int) -> Verdict {
        let rest = line.dropFirst(length)
        if character == backtick, rest.contains(backtick) { return .plain(simple: false) }
        return .fence(Fence(character: character, length: length), simple: true)
    }

    private static func closes(_ line: Slice<UnsafeBufferPointer<UInt8>>, _ open: Fence) -> Bool {
        var cursor = line.startIndex
        var indent = 0
        while cursor < line.endIndex, line[cursor] == space, indent < 4 {
            indent += 1
            cursor += 1
        }
        guard indent <= 3, cursor < line.endIndex, line[cursor] == open.character else { return false }
        var length = 0
        while cursor < line.endIndex, line[cursor] == open.character {
            length += 1
            cursor += 1
        }
        guard length >= open.length else { return false }
        return line[cursor...].allSatisfy { $0 == space || $0 == tab }
    }

    private static func hasFenceMarker(_ line: Slice<UnsafeBufferPointer<UInt8>>) -> Bool {
        var run = 0
        var runCharacter: UInt8 = 0
        for byte in line {
            guard byte == backtick || byte == tilde else {
                run = 0
                runCharacter = 0
                continue
            }
            if byte == runCharacter { run += 1 } else { (runCharacter, run) = (byte, 1) }
            if run >= 3 { return true }
        }
        return false
    }

    private static func startsList(_ line: Slice<UnsafeBufferPointer<UInt8>>) -> Bool {
        let first = line[line.startIndex]
        let next = line.index(after: line.startIndex)
        if first == UInt8(ascii: "-") || first == UInt8(ascii: "*") || first == UInt8(ascii: "+") {
            return next == line.endIndex || line[next] == space || line[next] == tab
        }
        let digits = line.prefix(while: { $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") })
        guard !digits.isEmpty else { return false }
        let after = line.index(line.startIndex, offsetBy: digits.count)
        return after < line.endIndex && (line[after] == UInt8(ascii: ".") || line[after] == UInt8(ascii: ")"))
    }
}

final class IncrementalMarkdown: @unchecked Sendable {
    static let shared = IncrementalMarkdown()

    private struct Entry {
        var texts: [String]
        var blocks: [[MarkdownBlock]]
    }

    private let capacity: Int
    private let parseGroup: @Sendable (String) -> [MarkdownBlock]?
    private let lock = NSLock()
    private var entries: [Entry] = []

    init(capacity: Int = 4, parseGroup: @escaping @Sendable (String) -> [MarkdownBlock]? = { MarkdownDocument.parsedGroup($0) }) {
        self.capacity = capacity
        self.parseGroup = parseGroup
    }

    func document(for source: String, remember: Bool = true) -> MarkdownDocument {
        guard Self.isChunkable(source), let texts = MarkdownChunker.groups(in: source), texts.count > 1 else {
            return MarkdownDocument(parsing: source)
        }
        let perf = PalPerf.begin("markdown.parse"); defer { perf.end() }
        let reused = reusableBlocks(for: texts)
        var groups = reused
        for text in texts.dropFirst(reused.count) {
            guard let parsed = parseGroup(text) else { return MarkdownDocument(parsing: source) }
            groups.append(parsed)
        }
        PalPerf.event("markdown.incremental.reused", count: reused.count)
        if remember { store(texts, groups, reused: reused.count) }
        return Self.assemble(groups)
    }

    private static func isChunkable(_ source: String) -> Bool {
        var text = source
        return text.withUTF8 { bytes in
            var hasInk = false
            var previous: UInt8 = 0
            for byte in bytes {
                switch byte {
                case UInt8(ascii: "\r"): return false
                case UInt8(ascii: ":") where previous == UInt8(ascii: "]"): return false
                case UInt8(ascii: "$") where previous == UInt8(ascii: "$"): return false
                case UInt8(ascii: "[") where previous == UInt8(ascii: "\\"): return false
                case UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\n"): break
                default: hasInk = true
                }
                previous = byte
            }
            return hasInk
        }
    }

    private func reusableBlocks(for texts: [String]) -> [[MarkdownBlock]] {
        lock.lock()
        defer { lock.unlock() }
        var best: [[MarkdownBlock]] = []
        for entry in entries {
            var matched = 0
            let limit = min(entry.texts.count, texts.count)
            while matched < limit, entry.texts[matched] == texts[matched] { matched += 1 }
            if matched > best.count { best = Array(entry.blocks[..<matched]) }
        }
        return best
    }

    private func store(_ texts: [String], _ blocks: [[MarkdownBlock]], reused: Int) {
        lock.lock()
        defer { lock.unlock() }
        if reused > 0, let index = entries.firstIndex(where: { $0.texts.count >= reused && $0.texts[0] == texts[0] }) {
            entries.remove(at: index)
        }
        entries.insert(Entry(texts: texts, blocks: blocks), at: 0)
        if entries.count > capacity { entries.removeLast(entries.count - capacity) }
    }

    private static func assemble(_ groups: [[MarkdownBlock]]) -> MarkdownDocument {
        var built: [MarkdownBlock] = []
        built.reserveCapacity(groups.reduce(0) { $0 + $1.count })
        for group in groups {
            let base = built.count
            for var block in group {
                block.id += base
                if let identity = block.quoteIdentity { block.quoteIdentity = identity + base }
                built.append(block)
            }
        }
        return MarkdownDocument(blocks: built)
    }
}
