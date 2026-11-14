import Foundation
import PalChat
import PalClient
import PalProtocol
import PalTransport
import Synchronization

final class TimelineScript: Sendable {
    static let sessionID = "s1"
    static let epoch = "e1"

    let capable: Bool
    let entries: Mutex<[TimelineEntryWire]>
    let lastSequence = Mutex(1)
    let overlappingPages = Mutex(false)
    private let counts = Mutex<[String: Int]>([:])
    private let received = Mutex<[String: [JSONValue]]>([:])
    private let overrides = Mutex<[String: BotScript.Override]>([:])

    init(capable: Bool = true, entries: [TimelineEntryWire]) {
        self.capable = capable
        self.entries = Mutex(entries)
    }

    var runtime: JSONValue? {
        guard capable else { return nil }
        return [
            "instance_id": "i", "profile_id": "bot", "authority_epoch": 1,
            "capabilities": [.string(TimelineWire.capability)],
        ]
    }

    func connector(_ url: URL) -> ScriptedConnector { ScriptedConnector(url: url, runtime: runtime) }

    func calls(_ method: String) -> [JSONValue] { received.withLock { $0[method] ?? [] } }

    func count(_ method: String) -> Int { counts.withLock { $0[method] ?? 0 } }

    func override(_ method: String, _ body: BotScript.Override?) {
        overrides.withLock { $0[method] = body }
    }

    func append(_ more: [TimelineEntryWire]) { entries.withLock { $0 += more } }

    func page(before: String?, limit: Int) -> FakeGateway.Reply {
        let all = entries.withLock { $0 }
        let end: Int
        if let before {
            guard let index = all.firstIndex(where: { $0.id == before }) else {
                return .failure(RPCError(code: 4004, message: "cursor_stale", data: ["reason": "cursor_stale"]))
            }
            end = overlappingPages.withLock { $0 } ? min(all.count, index + 2) : index
        } else {
            end = all.count
        }
        let start = max(0, end - limit)
        let page = TimelinePageWire(entries: Array(all[start..<end]), older: start > 0 ? all[start].id : nil, revision: "r1")
        return .result(Self.json(page))
    }

    static func json(_ value: some Encodable) -> JSONValue {
        (try? JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))) ?? .null
    }

    private var snapshot: [String: JSONValue] {
        let rows: [JSONValue] = entries.withLock { stored in
            stored.enumerated().map { index, entry in
                ["role": .string(entry.role.rawValue), "text": .string(entry.text), "row_id": .int(index + 1), "message_uid": .string(entry.id)]
            }
        }
        return [
            "session_id": .string(Self.sessionID),
            "messages": .array(rows),
            "running": false,
            "replay_epoch": .string(Self.epoch),
            "last_sequence": .int(lastSequence.withLock { $0 }),
            "execution_generation": 1,
            "pending": [],
            "prompts": [],
        ]
    }

    func handle(_ method: String, _ params: JSONValue?, _ connection: Int) -> FakeGateway.Reply {
        let number = counts.withLock { counts -> Int in
            counts[method, default: 0] += 1
            return counts[method] ?? 0
        }
        if let params { received.withLock { $0[method, default: []].append(params) } }
        if let reply = overrides.withLock({ $0[method] })?(number) { return reply }
        switch method {
        case "session.list":
            return .result(["sessions": [["session_id": .string(Self.sessionID), "title": "Bot Chat", "resolved_id": .string(Self.sessionID)]]])
        case "session.resume":
            var object = snapshot
            if let limit = params?[TimelineWire.resumeLimitParam]?.intValue, case .result(let page) = self.page(before: nil, limit: limit) {
                object["timeline"] = page
            }
            return .result(.object(object))
        case TimelineWire.pageMethod:
            return page(before: params?["before"]?.stringValue, limit: params?["limit"]?.intValue ?? 40)
        case "session.events.since":
            return .result([
                "events": [], "latest_seq": .int(lastSequence.withLock { $0 }), "replay_epoch": .string(Self.epoch),
                "snapshot_required": false,
            ])
        case "prompt.submit":
            return .result(["admission_id": .string("a-\(number)"), "status": "queued"])
        case "bot_threads.links":
            return .result(["links": []])
        default:
            return .failure(RPCError(code: -32601, message: "unknown_method", data: ["reason": "unknown_method"]))
        }
    }

    func event(_ type: String, seq: Int, payload: JSONValue) -> JSONValue {
        lastSequence.withLock { $0 = max($0, seq) }
        return [
            "type": .string(type),
            "session_id": .string(Self.sessionID),
            "seq": .int(seq),
            "replay_epoch": .string(Self.epoch),
            "payload": payload,
        ]
    }
}

func entries(_ range: ClosedRange<Int>) -> [TimelineEntryWire] {
    range.map { TimelineEntryWire(id: "m\($0)", role: $0.isMultiple(of: 2) ? .assistant : .user, text: "m\($0)", rowID: $0) }
}

func rowTexts(_ snapshot: TimelineSnapshot) -> [String] {
    snapshot.rows.map { row in
        switch row.item.content {
        case .user(let text, _): text
        case .assistant(let text, _, _): text
        default: row.item.id
        }
    }
}

func waitForTimeline(
    _ session: ChatSession,
    timeout: Duration = .seconds(5),
    _ predicate: @Sendable (TimelineSnapshot) -> Bool
) async -> TimelineSnapshot? {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        let snapshot = await session.timelineSnapshot
        if predicate(snapshot) { return snapshot }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return nil
}

func wantOlderUntil(
    _ session: ChatSession,
    timeout: Duration = .seconds(5),
    _ predicate: @Sendable (TimelineSnapshot) -> Bool
) async -> TimelineSnapshot? {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        let snapshot = await session.timelineSnapshot
        if predicate(snapshot) { return snapshot }
        await session.wantOlder()
        try? await Task.sleep(for: .milliseconds(20))
    }
    return nil
}
