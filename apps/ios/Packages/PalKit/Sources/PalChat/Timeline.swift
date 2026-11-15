import Foundation
import PalProtocol

public struct RowKey: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let value: UInt64

    public static func < (lhs: RowKey, rhs: RowKey) -> Bool { lhs.value < rhs.value }

    public var description: String { "row-\(value)" }
}

public enum OlderState: Sendable, Hashable {
    case more
    case loading
    case failed(retryAt: Date)
    case start
    case unknown
}

public struct ChatTimelineRow: Sendable, Hashable, Identifiable {
    public let id: RowKey
    public var item: TranscriptItem
    public var entryID: String?
    public var rowID: Int?
}

public struct TimelineSnapshot: Sendable, Equatable {
    public var version: UInt64
    public var sessionID: String?
    public var rows: [ChatTimelineRow]
    public var older: OlderState
    public var isRunning: Bool
    public var pendingPrompts: [PendingPrompt]
    public var hasPendingConnection: Bool
    public var lastError: String?
    public var executionGeneration: Int
    public var runningToolName: String?
    public var streamingText: String
}

enum OlderEdge: Sendable, Equatable {
    case more(String)
    case loading(String)
    case failed(String, retryAt: Date, attempt: Int)
    case start
    case unknown

    var state: OlderState {
        switch self {
        case .more: .more
        case .loading: .loading
        case .failed(_, let retryAt, _): .failed(retryAt: retryAt)
        case .start: .start
        case .unknown: .unknown
        }
    }

    init(cursor: String?) {
        self = cursor.map(OlderEdge.more) ?? .start
    }
}

enum TimelineRef: Sendable, Hashable {
    case entry(String)
    case uid(String)
    case segment(LiveSegment)
    case tool(String)
}

enum NewestMerge: Sendable, Equatable {
    case merged
    case gap(older: String)
}

struct Timeline: Sendable {
    private struct Part: Sendable {
        var key: RowKey
        var item: TranscriptItem
    }

    private struct Settled: Sendable {
        var wire: TimelineEntryWire
        var parts: [Part]
    }

    private(set) var live = Transcript()
    private(set) var older: OlderEdge = .unknown
    private(set) var revision: String?
    private var settled: [Settled] = []
    private var positions: [String: Int] = [:]
    private var boundaries: [String: String?] = [:]
    private var alias: [TimelineRef: RowKey] = [:]
    private var liveKeys: [String: RowKey] = [:]
    private var nextKey: UInt64 = 1
    private var failedAttempts = 0

    var settledIDs: [String] { settled.map(\.wire.id) }
    var settledWires: [TimelineEntryWire] { settled.map(\.wire) }

    func contains(entryID: String) -> Bool { positions[entryID] != nil }

    mutating func seed(_ cache: CachedTimeline) {
        guard settled.isEmpty else { return }
        revision = cache.revision
        older = cache.olderEdge
        if let first = cache.entries.first, older != .unknown { boundaries[first.id] = cache.olderCursor }
        rebuild(cache.entries, fresh: [], textMatch: false)
    }

    mutating func adoptLive(_ snapshot: SessionSnapshot) {
        var stripped = snapshot
        stripped.messages = []
        _ = live.reconcile(with: stripped)
        settleOverlay()
    }

    mutating func forceLive(_ snapshot: SessionSnapshot) {
        live.requestResync()
        adoptLive(snapshot)
    }

    mutating func noteApprovalChoice(_ choice: String?, promptID: String) {
        live.noteApprovalChoice(choice, promptID: promptID)
    }

    mutating func noteConnection(_ operation: ConnectionOperation) {
        live.noteConnection(operation)
    }

    mutating func lapseConnection(opID: String) {
        live.lapseConnection(opID: opID)
    }

    mutating func apply(_ frame: SessionEventFrame) -> ApplyOutcome {
        let outcome = live.apply(frame)
        if outcome == .applied { settleOverlay() }
        return outcome
    }

    mutating func echoUser(submissionID: String, text: String) {
        live.echoUser(submissionID: submissionID, text: text)
        assignLiveKeys()
    }

    mutating func markFailed(submissionID: String, reason: String) {
        live.markFailed(submissionID: submissionID, reason: reason)
    }

    @discardableResult
    mutating func mergeNewest(_ page: TimelinePageWire) -> NewestMerge {
        revision = page.revision
        let incoming = Self.unique(page.entries)
        guard !settled.isEmpty else {
            replace(with: page, entries: incoming)
            return .merged
        }
        guard let overlap = incoming.firstIndex(where: { positions[$0.id] != nil }), let start = positions[incoming[overlap].id] else {
            guard let cursor = page.older else {
                replace(with: page, entries: incoming)
                return .merged
            }
            return .gap(older: cursor)
        }
        let kept = Array(settled[..<start].map(\.wire))
        let keptIDs = Set(kept.map(\.id))
        let tail = incoming.filter { !keptIDs.contains($0.id) }
        if start == 0, let first = tail.first {
            older = OlderEdge(cursor: page.older)
            boundaries[first.id] = page.older
        } else if older == .unknown {
            older = OlderEdge(cursor: page.older)
        }
        let fresh = Set(tail.map(\.id)).subtracting(positions.keys)
        rebuild(kept + tail, fresh: fresh, textMatch: true)
        return .merged
    }

    mutating func reset(_ page: TimelinePageWire) {
        revision = page.revision
        replace(with: page, entries: Self.unique(page.entries))
    }

    mutating func beginLoadingOlder(now: Date) -> String? {
        switch older {
        case .more(let cursor):
            older = .loading(cursor)
            return cursor
        case .failed(let cursor, let retryAt, _) where retryAt <= now:
            older = .loading(cursor)
            return cursor
        default:
            return nil
        }
    }

    @discardableResult
    mutating func prepend(_ page: TimelinePageWire, requested cursor: String) -> Bool {
        guard older == .loading(cursor) else { return false }
        let fresh = Self.unique(page.entries).filter { positions[$0.id] == nil }
        older = OlderEdge(cursor: page.older)
        failedAttempts = 0
        if let first = fresh.first { boundaries[first.id] = page.older }
        rebuild(fresh + settled.map(\.wire), fresh: [], textMatch: false)
        return true
    }

    mutating func failOlder(requested cursor: String, now: Date, backoff: (Int) -> TimeInterval) {
        guard older == .loading(cursor) else { return }
        let attempt = failedAttempts + 1
        failedAttempts = attempt
        older = .failed(cursor, retryAt: now.addingTimeInterval(backoff(attempt)), attempt: attempt)
    }

    func rows(links: [BotThreadLink]) -> [ChatTimelineRow] {
        var rows: [ChatTimelineRow] = []
        for entry in settled {
            for part in entry.parts {
                rows.append(ChatTimelineRow(id: part.key, item: part.item, entryID: entry.wire.id, rowID: entry.wire.rowID))
            }
        }
        for item in live.items {
            guard let key = liveKeys[item.id] else { continue }
            rows.append(ChatTimelineRow(id: key, item: item, entryID: nil, rowID: nil))
        }
        return Self.fold(rows.filter(Self.isShown), links: links)
    }

    private mutating func assignLiveKeys() {
        for item in live.items where liveKeys[item.id] == nil { liveKeys[item.id] = mint() }
    }

    func cacheable(sessionID: String, maxEntries: Int = CachedTimeline.maxEntries, maxBytes: Int = CachedTimeline.maxBytes) -> CachedTimeline? {
        var budget = maxBytes
        var start = settled.count
        var best: (start: Int, edge: OlderEdge)?
        for index in settled.indices.reversed() {
            let cost = CachedTimeline.byteCost(settled[index].wire)
            guard settled.count - index <= maxEntries, cost <= budget else { break }
            budget -= cost
            start = index
            if index == 0 {
                best = (0, older == .start ? .start : boundaryEdge(settled[0].wire.id))
            } else if let cursor = boundaries[settled[index].wire.id] {
                best = (index, OlderEdge(cursor: cursor))
            }
        }
        let chosen = best ?? (start, .unknown)
        guard chosen.start < settled.count else { return nil }
        return CachedTimeline(
            sessionID: sessionID,
            entries: settled[chosen.start...].map(\.wire),
            older: chosen.edge,
            revision: revision
        )
    }

    private func boundaryEdge(_ id: String) -> OlderEdge {
        switch older {
        case .more(let cursor), .loading(let cursor), .failed(let cursor, _, _): .more(cursor)
        case .start: .start
        case .unknown: boundaries[id].map(OlderEdge.init(cursor:)) ?? .unknown
        }
    }

    private mutating func replace(with page: TimelinePageWire, entries: [TimelineEntryWire]) {
        older = OlderEdge(cursor: page.older)
        failedAttempts = 0
        boundaries = [:]
        if let first = entries.first { boundaries[first.id] = page.older }
        let fresh = Set(entries.map(\.id)).subtracting(positions.keys)
        rebuild(entries, fresh: fresh, textMatch: true)
    }

    private mutating func mint() -> RowKey {
        defer { nextKey += 1 }
        return RowKey(value: nextKey)
    }

    private mutating func rebuild(_ wires: [TimelineEntryWire], fresh: Set<String>, textMatch: Bool) {
        let previous = alias
        alias = [:]
        var used: Set<RowKey> = []
        var bound: Set<String> = []
        var built: [Settled] = []
        built.reserveCapacity(wires.count)
        for wire in wires {
            var parts: [Part] = []
            for (item, refs) in Self.project(wire) {
                var key = refs.lazy.compactMap { previous[$0] }.first { !used.contains($0) }
                if key == nil, fresh.contains(wire.id), let match = liveMatch(item, refs: refs, textMatch: textMatch, excluding: bound) {
                    bound.insert(match)
                    key = liveKeys[match]
                }
                let resolved = key ?? mint()
                used.insert(resolved)
                for ref in refs { alias[ref] = resolved }
                parts.append(Part(key: resolved, item: item))
            }
            built.append(Settled(wire: wire, parts: parts))
        }
        settled = built
        positions = Dictionary(uniqueKeysWithValues: built.enumerated().map { ($1.wire.id, $0) })
        boundaries = boundaries.filter { positions[$0.key] != nil }
        live.dropLiveItems(bound)
        for id in bound { liveKeys[id] = nil }
        settleOverlay()
    }

    private mutating func settleOverlay() {
        let settledItems = Set(live.items.filter { item in
            !Self.isStreaming(item) && Self.liveRefs(item).contains { alias[$0] != nil }
        }.map(\.id))
        live.dropLiveItems(settledItems)
        for id in settledItems { liveKeys[id] = nil }
        assignLiveKeys()
    }

    private func liveMatch(_ item: TranscriptItem, refs: [TimelineRef], textMatch: Bool, excluding bound: Set<String>) -> String? {
        let candidates = live.items.filter { !bound.contains($0.id) && !Self.isStreaming($0) }
        if let byRef = candidates.first(where: { !Set(Self.liveRefs($0)).isDisjoint(with: refs) }) { return byRef.id }
        guard textMatch else { return nil }
        return candidates.first { Self.sameText($0.content, item.content) }?.id
    }

    private static func sameText(_ live: TranscriptItem.Content, _ stored: TranscriptItem.Content) -> Bool {
        switch (live, stored) {
        case (.user(let a, .sent), .user(let b, _)): a == b
        case (.assistant(let a, _, false), .assistant(let b, _, _)): !a.isEmpty && a == b
        default: false
        }
    }

    private static func isStreaming(_ item: TranscriptItem) -> Bool {
        if case .assistant(_, _, true) = item.content { return true }
        return false
    }

    private static func liveRefs(_ item: TranscriptItem) -> [TimelineRef] {
        var refs: [TimelineRef] = []
        if let uid = item.uid { refs.append(.uid(uid)) }
        if let segment = item.liveSegment { refs.append(.segment(segment)) }
        switch item.content {
        case .tool(let call): refs.append(.tool(call.toolID))
        case .clarifyAnswered where item.id.hasPrefix(toolPrefix): refs.append(.tool(String(item.id.dropFirst(toolPrefix.count))))
        default: break
        }
        return refs
    }

    private static let toolPrefix = "tool:"

    private static func unique(_ entries: [TimelineEntryWire]) -> [TimelineEntryWire] {
        var seen: Set<String> = []
        return entries.filter { seen.insert($0.id).inserted }
    }

    private static func serverDate(_ timestamp: Double?) -> Date? {
        timestamp.flatMap { $0.isFinite && $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
    }

    private static func messageUID(of id: String) -> String? {
        guard !id.hasPrefix("r:"), !id.hasPrefix("l:"), !id.contains("#") else { return nil }
        return id
    }

    static func project(_ wire: TimelineEntryWire) -> [(TranscriptItem, [TimelineRef])] {
        let date = serverDate(wire.timestamp)
        let uid = messageUID(of: wire.id)
        var mainRefs: [TimelineRef] = [.entry(wire.id)]
        if let uid { mainRefs.append(.uid(uid)) }
        if let turnID = wire.turnID, let segment = wire.segment { mainRefs.append(.segment(LiveSegment(turnID: turnID, segment: segment))) }
        var parts: [(TranscriptItem, [TimelineRef])] = []
        switch wire.role {
        case .user, .notice:
            var inbound = InboundKind.classify(text: wire.text, displayKind: wire.displayKind)
            if wire.role == .notice, inbound == .person { inbound = .systemNotification }
            parts.append((TranscriptItem(
                id: wire.id, content: .user(text: wire.text, delivery: .sent), timestamp: date, inbound: inbound, uid: uid
            ), mainRefs))
        case .assistant:
            if !wire.text.isEmpty {
                parts.append((TranscriptItem(
                    id: wire.id,
                    content: .assistant(text: wire.text, reasoning: wire.reasoning ?? "", isStreaming: false),
                    timestamp: date,
                    uid: uid
                ), mainRefs))
            }
            for tool in wire.tools { parts += toolParts(tool, date: date) }
            if parts.isEmpty == false, wire.text.isEmpty { parts[0].1 += mainRefs }
        }
        return parts
    }

    private static func toolParts(_ tool: TimelineToolWire, date: Date?) -> [(TranscriptItem, [TimelineRef])] {
        if tool.name.isEmpty || tool.name == "clarify", let result = ClarifyResult(json: tool.resultText) {
            return result.records.enumerated().map { index, record in
                let ref = "\(tool.callID)#\(index)"
                return (TranscriptItem(id: toolPrefix + ref, content: .clarifyAnswered(record), timestamp: date), [.tool(ref)])
            }
        }
        let call = ToolCall(
            toolID: tool.callID,
            name: tool.name.isEmpty ? "tool" : tool.name,
            status: .finished,
            summary: tool.summary,
            prompt: tool.args?["prompt"]?.stringValue,
            aspectRatio: tool.args?["aspect_ratio"]?.stringValue,
            result: tool.result
        )
        return [(TranscriptItem(id: toolPrefix + tool.callID, content: .tool(call), timestamp: date), [.tool(tool.callID)])]
    }

    static func legacyEntries(_ messages: [WireMessage]) -> [TimelineEntryWire] {
        messages.enumerated().compactMap { index, message in
            let id = message.messageUID ?? message.rowID.map { "r:\($0)" } ?? "l:\(index)"
            let text = message.plainText
            switch message.role {
            case "user":
                guard message.displayKind != "hidden" else { return nil }
                return TimelineEntryWire(
                    id: id, role: .user, text: text, timestamp: message.timestamp,
                    displayKind: message.displayKind, displayMetadata: message.displayMetadata, rowID: message.rowID
                )
            case "assistant":
                guard !text.isEmpty else { return nil }
                return TimelineEntryWire(
                    id: id, role: .assistant, text: text, reasoning: message.reasoning,
                    timestamp: message.timestamp, displayKind: message.displayKind, rowID: message.rowID
                )
            case "tool":
                let callID = message.toolCallID ?? id
                return TimelineEntryWire(
                    id: message.rowID.map { "r:\($0)" } ?? "t:\(callID)", role: .assistant, text: "",
                    timestamp: message.timestamp, rowID: message.rowID,
                    tools: [TimelineToolWire(callID: callID, name: message.name ?? "", result: .string(text))]
                )
            default:
                return nil
            }
        }
    }

    private static func isShown(_ row: ChatTimelineRow) -> Bool {
        if TranscriptVisibility.isHidden(row.item) { return false }
        switch row.item.content {
        case .tool(let call): return call.imageGeneration != nil
        case .assistant(_, _, let streaming): return !streaming
        default: return true
        }
    }

    private static func fold(_ rows: [ChatTimelineRow], links: [BotThreadLink]) -> [ChatTimelineRow] {
        guard !links.isEmpty else { return rows }
        var owner: [String: BotThreadLink] = [:]
        for link in links {
            for uid in [link.anchorUID] + link.coveredUIDs where owner[uid] == nil { owner[uid] = link }
        }
        var placed: Set<String> = []
        return rows.compactMap { row in
            guard let uid = row.item.uid, let link = owner[uid] else { return row }
            guard placed.insert(link.anchorUID).inserted else { return nil }
            var folded = row
            folded.item = TranscriptItem(
                id: "bot-thread:\(link.anchorUID)", content: .botThread(link), timestamp: row.item.timestamp, uid: link.anchorUID
            )
            return folded
        }
    }
}
