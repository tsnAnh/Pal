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
    public var forwardedKeys: [RowKey: RowKey] = [:]
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
    case connection(String)
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

    var live = Transcript()
    private(set) var older: OlderEdge = .unknown
    private(set) var revision: String?
    private var settled: [Settled] = []
    private var positions: [String: Int] = [:]
    private var boundaries: [String: String?] = [:]
    private var alias: [TimelineRef: RowKey] = [:]
    private var liveKeys: [String: RowKey] = [:]
    private var anchors: [RowKey: RowKey] = [:]
    private(set) var forwarded: [RowKey: RowKey] = [:]
    private var nextKey: UInt64 = 1
    private var failedAttempts = 0
    private var generation = 0
    private var liveBirth: [String: Int] = [:]
    private var unbound: [String: Int] = [:]

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

    mutating func echoUser(submissionID: String, text: String, carriesImage: Bool = false) {
        live.echoUser(submissionID: submissionID, text: text, carriesImage: carriesImage)
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
        Self.fold(placed().filter(Self.isShown), links: links)
    }

    private func placed() -> [ChatTimelineRow] {
        let stored = settled.flatMap { entry in
            entry.parts.map { ChatTimelineRow(id: $0.key, item: $0.item, entryID: entry.wire.id, rowID: entry.wire.rowID) }
        }
        let overlay = live.items.compactMap { item in
            liveKeys[item.id].map { ChatTimelineRow(id: $0, item: item, entryID: nil, rowID: nil) }
        }
        guard !overlay.isEmpty else { return stored }
        let present = Set(stored.map(\.id)).union(overlay.map(\.id))
        var following: [RowKey: [ChatTimelineRow]] = [:]
        var trailing: [ChatTimelineRow] = []
        for row in overlay {
            if let anchor = anchor(of: row.id, among: present) {
                following[anchor, default: []].append(row)
            } else {
                trailing.append(row)
            }
        }
        var ordered: [ChatTimelineRow] = []
        ordered.reserveCapacity(stored.count + overlay.count)
        func emit(_ row: ChatTimelineRow) {
            ordered.append(row)
            for next in following.removeValue(forKey: row.id) ?? [] { emit(next) }
        }
        stored.forEach(emit)
        trailing.forEach(emit)
        return ordered
    }

    private func anchor(of key: RowKey, among present: Set<RowKey>) -> RowKey? {
        var cursor = anchors[key]
        for _ in 0...anchors.count {
            guard let current = cursor else { return nil }
            if present.contains(current) { return current }
            cursor = forwarded[current] ?? anchors[current]
        }
        return nil
    }

    mutating func assignLiveKeys() {
        let items = live.items
        guard let lastPainted = items.lastIndex(where: { liveKeys[$0.id] != nil }) ?? (items.isEmpty ? nil : -1),
              items.contains(where: { liveKeys[$0.id] == nil })
        else { return }
        var tail = placed().last?.id
        for index in items.indices where liveKeys[items[index].id] == nil {
            let key = mint()
            liveKeys[items[index].id] = key
            liveBirth[items[index].id] = generation
            if index < lastPainted {
                anchors[key] = index > 0
                    ? liveKeys[items[index - 1].id]
                    : items.dropFirst().compactMap { liveKeys[$0.id] }.first.flatMap { anchors[$0] }
            } else {
                anchors[key] = tail
                tail = key
            }
        }
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
        generation += 1
        let previous = alias
        let receipted = receiptMatches(wires)
        alias = [:]
        var used: Set<RowKey> = []
        var bound: Set<String> = []
        var late: [String: RowKey] = [:]
        var built: [Settled] = []
        built.reserveCapacity(wires.count)
        for wire in wires {
            var parts: [Part] = []
            var matched = false
            for (item, refs) in Self.project(wire) {
                let spoken = item.isAssistant ? receipted[wire.id] : nil
                var key = refs.lazy.compactMap { previous[$0] }.first { !used.contains($0) }
                if key == nil, fresh.contains(wire.id),
                   let match = liveMatch(item, refs: refs, rowID: wire.rowID, receipted: spoken, textMatch: textMatch, excluding: bound)
                {
                    bound.insert(match)
                    key = liveKeys[match]
                    matched = true
                }
                let resolved = key ?? mint()
                used.insert(resolved)
                for ref in refs { alias[ref] = resolved }
                if let spoken, !bound.contains(spoken) { late[spoken] = resolved }
                parts.append(Part(key: resolved, item: item))
            }
            built.append(Settled(wire: wire, parts: parts))
            if textMatch, fresh.contains(wire.id), !matched { unbound[wire.id] = generation }
        }
        settled = built
        positions = Dictionary(uniqueKeysWithValues: built.enumerated().map { ($1.wire.id, $0) })
        boundaries = boundaries.filter { positions[$0.key] != nil }
        unbound = unbound.filter { positions[$0.key] != nil }
        live.dropLiveItems(bound)
        for id in bound { liveKeys[id] = nil }
        settleOverlay(late)
    }

    private mutating func settleOverlay(_ late: [String: RowKey] = [:]) {
        var settledKeys = late
        if live.items.contains(where: { $0.receipt != nil }) {
            for (wireID, liveID) in receiptMatches(settledWires) where settledKeys[liveID] == nil {
                settledKeys[liveID] = positions[wireID].flatMap { settled[$0].parts.first(where: \.item.isAssistant)?.key }
            }
        }
        let aliases = alias
        for item in live.items where !Self.isStreaming(item) && settledKeys[item.id] == nil {
            settledKeys[item.id] = Self.liveRefs(item).lazy.compactMap { aliases[$0] }.first
        }
        let settledItems = Set(live.items.map(\.id)).intersection(settledKeys.keys)
        for id in settledItems {
            if let liveKey = liveKeys.removeValue(forKey: id), let key = settledKeys[id], key != liveKey { forwarded[liveKey] = key }
        }
        live.dropLiveItems(settledItems)
        assignLiveKeys()
        bindLate()
    }

    private mutating func bindLate() {
        guard !unbound.isEmpty else { return }
        var taken: Set<String> = []
        for position in unbound.keys.compactMap({ positions[$0] }).sorted() {
            let entryID = settled[position].wire.id
            guard let seen = unbound[entryID] else { continue }
            for part in settled[position].parts {
                let candidate = live.items.first { item in
                    !taken.contains(item.id) && !Self.isStreaming(item) && (liveBirth[item.id] ?? generation) < seen
                        && Self.sameText(item, part.item)
                }
                if let candidate {
                    taken.insert(candidate.id)
                    unbound[entryID] = nil
                }
            }
        }
        live.dropLiveItems(taken)
        for id in taken { liveKeys[id] = nil; liveBirth[id] = nil }
        liveBirth = liveBirth.filter { liveKeys[$0.key] != nil }
    }

    private func receiptMatches(_ wires: [TimelineEntryWire]) -> [String: String] {
        var spokenByTurn: [Set<Int>: (count: Int, ids: [Int: String])] = [:]
        for item in live.items where !Self.isStreaming(item) {
            guard let receipt = item.receipt else { continue }
            spokenByTurn[receipt.rowIDs, default: (receipt.count, [:])].ids[receipt.ordinal] = item.id
        }
        var matches: [String: String] = [:]
        for (rows, spoken) in spokenByTurn {
            let stored = wires.filter { wire in
                wire.role == .assistant && wire.rowID.map(rows.contains) == true && !Transcript.isBlank(wire.text)
            }
            guard stored.count == spoken.count else { continue }
            for (ordinal, wire) in stored.enumerated() {
                if let id = spoken.ids[ordinal] { matches[wire.id] = id }
            }
        }
        return matches
    }

    private func liveMatch(
        _ item: TranscriptItem, refs: [TimelineRef], rowID: Int?, receipted: String?, textMatch: Bool, excluding bound: Set<String>
    ) -> String? {
        let candidates = live.items.filter { !bound.contains($0.id) && !Self.isStreaming($0) }
        if let byRef = candidates.first(where: { !Set(Self.liveRefs($0)).isDisjoint(with: refs) }) { return byRef.id }
        if let receipted, candidates.contains(where: { $0.id == receipted }) { return receipted }
        guard textMatch else { return nil }
        return candidates.first { candidate in
            candidate.uid == nil && Self.sameText(candidate, item)
                && candidate.receipt.map { receipt in rowID.map(receipt.rowIDs.contains) ?? false } != false
        }?.id
    }

    private static func sameText(_ live: TranscriptItem, _ stored: TranscriptItem) -> Bool {
        switch (live.content, stored.content) {
        case (.user(let a, .sent), .user(let b, _)):
            let body = MessageImages.extract(from: b, role: .user)
            guard live.carriesImage == !body.images.isEmpty else { return false }
            return Transcript.sameBody(a, body.text) || (live.carriesImage && body.text.isEmpty)
        case (.assistant(let a, _, false), .assistant(let b, _, _)): return !Transcript.isBlank(a) && Transcript.sameBody(a, b)
        default: return live.content == .noProvider && stored.content == .noProvider
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
        case .connection(let card): refs.append(.connection(card.operation.opID))
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
            var inbound = InboundKind.classify(text: wire.text, of: wire)
            if wire.role == .notice, inbound == .person { inbound = .internalNotice }
            parts.append((TranscriptItem(
                id: wire.id, content: .user(text: wire.text, delivery: .sent), timestamp: date, inbound: inbound, uid: uid
            ), mainRefs))
        case .assistant:
            if !wire.text.isEmpty {
                parts.append((TranscriptItem(
                    id: wire.id,
                    content: .reply(wire.text, reasoning: wire.reasoning ?? "", from: wire),
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
        if tool.name.isEmpty || tool.name == ConnectionCard.toolName,
           let operation = ConnectionOperation(toolResult: tool.resultText) ?? tool.result.flatMap(ConnectionOperation.init(value:))
        {
            let item = TranscriptItem(id: ConnectionCard.itemID(operation.opID), content: .connection(ConnectionCard(operation: operation.closed())), timestamp: date)
            return [(item, [.tool(tool.callID), .connection(operation.opID)])]
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
                    timestamp: message.timestamp, displayKind: message.displayKind, displayMetadata: message.displayMetadata, rowID: message.rowID
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
