import Foundation
import Observation
import PalAuth
import PalClient
import PalDesign
import PalProtocol
import PalREST
import PalRoster
import Synchronization
import Testing

@testable import Pal
@testable import PalChat

struct RebuildTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> HTTPResult { throw URLError(.cannotConnectToHost) }
}

final class RebuildHits: Sendable {
    private let count = Mutex(0)
    func bump() { count.withLock { $0 += 1 } }
    var value: Int { count.withLock { $0 } }
}

struct RebuildSplitMix: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@MainActor
func rebuildRoster() throws -> RosterModel {
    let root = FileManager.default.temporaryDirectory.appending(path: "chat-model-rebuild-\(UUID().uuidString)", directoryHint: .isDirectory)
    let identity = DeviceIdentity(deviceID: "0B7F3F2E-5A4B-4E5E-9D1C-1F2E3D4C5B6A", formFactor: .phone, appVersion: "0.1.0 (1)")
    let transport = RebuildTransport()
    let connection = ConnectionModel(
        auth: try AuthSession(store: InMemoryCredentialStore(), transport: transport),
        transport: transport,
        diagnostics: .silent,
        initialBaseURL: "http://chat-model-rebuild.invalid",
        presence: ReachPresence(identity: identity),
        cache: CacheStore(root: root)
    )
    return RosterModel(connection: connection)
}

let rebuildBotName = "scout"

@MainActor
func rebuildChatModel(
    lastSeen: Date? = nil, streamInterval: Duration = .zero, drafts: DraftStore? = nil, botName: String = rebuildBotName
) throws -> ChatModel {
    let roster = try rebuildRoster()
    let row = BotRow(
        name: botName, isDefault: false, isPrimary: false, isPinned: false, displayName: "Scout", conversationID: nil,
        preview: ClassifiedPreview(kind: .plain, text: ""), lastActive: nil,
        spec: BotAvatarSpec(name: botName, uiMeta: nil, photo: nil), accent: nil, usesPrimaryLook: false, sessionIDs: []
    )
    let defaults = try #require(UserDefaults(suiteName: "chat-model-rebuild-\(UUID().uuidString)"))
    let store = ChatLastSeenStore(defaults: defaults)
    if let lastSeen { store.record(lastSeen, for: botName) }
    let links = drafts.map { BotLinks(connection: roster.connection, drafts: $0) } ?? BotLinks(connection: roster.connection)
    let model = ChatModel(bot: row, links: links, roster: roster, lastSeenStore: store)
    model.streamPacer.interval = streamInterval
    return model
}

let rebuildStart = Date(timeIntervalSince1970: 1_800_000_000)

func rebuildAt(_ seconds: TimeInterval) -> Date { rebuildStart.addingTimeInterval(seconds) }

func rebuildAssistant(_ id: String, _ text: String, streaming: Bool = false, at date: Date? = nil) -> TranscriptItem {
    TranscriptItem(id: id, content: .assistant(text: text, reasoning: "", isStreaming: streaming), timestamp: date)
}

func rebuildUser(_ id: String, _ text: String, delivery: TranscriptItem.Delivery = .sent, at date: Date? = nil) -> TranscriptItem {
    TranscriptItem(id: id, content: .user(text: text, delivery: delivery), timestamp: date)
}

func rebuildAnswered(_ call: String, _ index: Int, _ question: String, at date: Date? = nil) -> TranscriptItem {
    TranscriptItem(
        id: "tool:\(call)#\(index)",
        content: .clarifyAnswered(ClarifyRecord(question: question, answer: .answered(["yes"]))),
        timestamp: date
    )
}

struct RebuildWorld {
    var rows: [(key: UInt64, item: TranscriptItem)] = []
    var sessionID: String? = "s1"
    var isRunning = true
    var older = OlderState.more
    var nextKey: UInt64 = 100
    var lowKey: UInt64 = 99

    mutating func append(_ item: TranscriptItem) {
        rows.append((nextKey, item))
        nextKey += 1
    }

    mutating func prepend(_ items: [TranscriptItem]) {
        let keys = items.indices.map { lowKey - UInt64(items.count - 1 - $0) }
        lowKey -= UInt64(items.count)
        rows.insert(contentsOf: zip(keys, items).map { ($0, $1) }, at: 0)
    }

    mutating func editLast(_ change: (inout TranscriptItem) -> Void) {
        change(&rows[rows.count - 1].item)
    }

    func snapshot(version: UInt64) -> TimelineSnapshot {
        TimelineSnapshot(
            version: version,
            sessionID: sessionID,
            rows: rows.map { ChatTimelineRow(id: RowKey(value: $0.key), item: $0.item, entryID: nil, rowID: Int($0.key)) },
            older: older,
            isRunning: isRunning,
            pendingPrompts: [],
            hasPendingConnection: false,
            lastError: nil,
            executionGeneration: 0,
            runningToolName: nil,
            streamingText: ""
        )
    }
}

@MainActor
final class RebuildHarness {
    let model: ChatModel
    let oracle: ChatModel
    var world = RebuildWorld()
    private var version: UInt64 = 0
    private(set) var steps = 0

    init(lastSeen: Date? = nil, world: RebuildWorld = RebuildWorld()) throws {
        model = try rebuildChatModel(lastSeen: lastSeen)
        oracle = try rebuildChatModel(lastSeen: lastSeen)
        self.world = world
    }

    func push(_ label: String = "") {
        version += 1
        steps += 1
        let next = world.snapshot(version: version)
        model.apply(next)
        if oracle.snapshot == nil {
            oracle.apply(next)
        } else {
            oracle.snapshot = next
            oracle.rebuild()
        }
        assertEquivalent(label)
    }

    func phase(_ phase: ChatPhase, _ label: String = "") {
        model.applyPhase(phase)
        oracle.applyPhase(phase)
        assertEquivalent(label)
    }

    func find(_ query: String) {
        for target in [model, oracle] {
            target.beginFinding()
            target.findQuery = query
        }
        assertEquivalent("find \(query)")
    }

    private static func sameRows(_ lhs: [ChatRow], _ rhs: [ChatRow]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { left, right in
            var aligned = right
            if let a = left.separator, let b = right.separator, abs(a.timeIntervalSince(b)) < 5 { aligned.separator = a }
            return left == aligned
        }
    }

    func assertEquivalent(_ label: String) {
        let context = Comment(rawValue: "step \(steps) \(label)")
        #expect(Self.sameRows(model.rows, oracle.rows), context)
        #expect(Self.sameRows(model.rowsNewestFirst, oracle.rowsNewestFirst), context)
        #expect(model.rowIDs == oracle.rowIDs, context)
        #expect(model.rowsNewestFirst == Array(model.rows.reversed()), context)
        #expect(model.rowIDs == model.rows.map(\.id), context)
        #expect(model.windowRows == model.rows, context)
        #expect(model.windowRowIDs == model.rowIDs, context)
        #expect(model.hiddenOlder == 0, context)
        #expect(model.findMatches == oracle.findMatches, context)
        #expect(model.findPosition == oracle.findPosition, context)
        #expect(model.currentFindRowID == oracle.currentFindRowID, context)
        #expect(model.isRunning == oracle.isRunning, context)
        #expect(model.workingStatus == oracle.workingStatus, context)
        #expect(model.hasPendingClarify == oracle.hasPendingClarify, context)
        #expect(model.hasPendingPrompt == oracle.hasPendingPrompt, context)
        #expect(model.isOpening == oracle.isOpening, context)
        #expect(model.connection == oracle.connection, context)
    }
}

@MainActor
func rebuildNotifications(_ model: ChatModel, _ body: () -> Void) -> [String: Int] {
    let reads: [(String, @MainActor () -> Void)] = [
        ("rows", { _ = model.rows }),
        ("rowsNewestFirst", { _ = model.rowsNewestFirst }),
        ("rowIDs", { _ = model.rowIDs }),
        ("windowRows", { _ = model.windowRows }),
        ("windowRowIDs", { _ = model.windowRowIDs }),
        ("hiddenOlder", { _ = model.hiddenOlder }),
        ("connection", { _ = model.connection }),
        ("isRunning", { _ = model.isRunning }),
        ("workingStatus", { _ = model.workingStatus }),
        ("hasPendingClarify", { _ = model.hasPendingClarify }),
        ("hasPendingPrompt", { _ = model.hasPendingPrompt }),
        ("olderHistory", { _ = model.olderHistory }),
        ("findMatches", { _ = model.findMatches }),
        ("findPosition", { _ = model.findPosition }),
    ]
    let hits = reads.map { _ in RebuildHits() }
    for (index, read) in reads.enumerated() {
        let counter = hits[index]
        withObservationTracking({ read.1() }, onChange: { counter.bump() })
    }
    body()
    return Dictionary(uniqueKeysWithValues: reads.indices.map { (reads[$0].0, hits[$0].value) })
}

func rebuildConversation(streamingText: String = "Hello") -> RebuildWorld {
    var world = RebuildWorld()
    world.append(rebuildUser("u1", "first question", at: rebuildAt(0)))
    world.append(rebuildAssistant("a1", "first answer", at: rebuildAt(20)))
    world.append(rebuildUser("u2", "second question", at: rebuildAt(400)))
    world.append(rebuildAssistant("a2", streamingText, streaming: true, at: rebuildAt(420)))
    return world
}
