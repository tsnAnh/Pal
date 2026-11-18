import Foundation
import PalKanban
import PalProtocol
import PalTransport
import Testing

@MainActor
@Suite("Kanban cache and readiness")
struct KanbanCacheTests {
    private let cache = CacheStore(root: FileManager.default.temporaryDirectory.appending(path: "kanban-cache-\(UUID().uuidString)", directoryHint: .isDirectory))
    private let account = "https://gw.example|me"

    private var url: URL { cache.fileURL(name: KanbanDiskCache.name(board: "ops"), account: account) }

    private func disk(now: Date = Date()) -> KanbanDiskCache {
        KanbanDiskCache(store: cache, account: account, now: { now })
    }

    private func store(_ script: KanbanScript, disk: KanbanDiskCache? = nil) -> KanbanStore {
        KanbanStore(service: KanbanService(gateway: script.gateway), disk: disk ?? self.disk(), sleep: { _ in })
    }

    private static let cards = [KanbanJSON.card("t1", title: "Ship the cache"), KanbanJSON.card("t2", title: "Fix the title")]

    private func detail(_ task: String, body: String, status: String = "ready") -> JSONValue {
        [
            "state": "present", "scope": KanbanJSON.scope("gw"),
            "detail": ["card": KanbanJSON.card(task, status: status), "body": .string(body), "cursor": "c"],
        ]
    }

    private func titles(_ rows: [KanbanCardRow]?) -> [String: String]? {
        rows.map { Dictionary(uniqueKeysWithValues: $0.map { ($0.card.taskID, $0.displayTitle) }) }
    }

    private func warmed() async -> KanbanStore {
        let script = KanbanScript()
        script.enqueue("kanban.board.snapshot", KanbanJSON.snapshot(Self.cards, cursor: "c0"))
        script.enqueue("kanban.card.get", detail("t1", body: "# Ship the cache"))
        script.enqueue("kanban.card.get", detail("t2", body: "# Fix the title"))
        let first = store(script)
        await first.refreshSnapshot(board: "ops")
        await first.prefetchDetails(board: "ops")
        cache.drain()
        return first
    }

    @Test("cold start shows nothing until every card has its detail, then the complete board at once")
    func coldStartGatesOnDetails() async throws {
        let script = KanbanScript()
        script.enqueue("kanban.board.snapshot", KanbanJSON.snapshot(Self.cards, cursor: "c0"))
        let store = store(script)
        await store.refreshSnapshot(board: "ops")
        #expect(store.session.cache("ops") != nil)
        #expect(store.visibleRows(board: "ops") == nil, "a card without its detail would show the task id and then change")
        script.enqueue("kanban.card.get", detail("t1", body: "# Ship the cache"))
        script.enqueue("kanban.card.get", detail("t2", body: "# Fix the title"))
        await store.prefetchDetails(board: "ops")
        #expect(titles(store.visibleRows(board: "ops"))?.values.sorted() == ["Fix the title", "Ship the cache"])
    }

    @Test("the title is the board name or nothing, never the slug")
    func titleNeverSlug() async throws {
        let script = KanbanScript()
        let store = store(script)
        #expect(store.boardName("ops") == nil)
        guard case .object(var page) = KanbanJSON.snapshot([KanbanJSON.card("t1")], cursor: "c0") else { return }
        page["board"] = ["scope": KanbanJSON.scope("gw"), "name": "Ops"]
        script.enqueue("kanban.board.snapshot", .object(page))
        await store.refreshSnapshot(board: "ops")
        #expect(store.boardName("ops") == "Ops")
    }

    @Test("a restart restores the same board from disk with the gateway down, and no request is needed to show it")
    func restartRestoresFromDisk() async throws {
        let first = await warmed()
        let down = KanbanScript()
        let second = store(down)
        await second.restore(board: "ops")
        #expect(second.session.cache("ops") == first.session.cache("ops"))
        #expect(titles(second.visibleRows(board: "ops")) == titles(first.visibleRows(board: "ops")))
        #expect(down.allMethods.isEmpty)
        _ = await second.pollOnce(board: "ops")
        #expect(titles(second.visibleRows(board: "ops")) == titles(first.visibleRows(board: "ops")), "a failed refresh keeps the cached view")
        #expect(second.load(of: "ops") == .unreachable)
    }

    @Test("an identical snapshot leaves the session equal, one changed card changes only that card")
    func refreshAppliesOnlyRealDiffs() async throws {
        _ = await warmed()
        let script = KanbanScript()
        let store = store(script)
        await store.restore(board: "ops")
        let before = store.session
        script.enqueue("kanban.board.snapshot", KanbanJSON.snapshot(Self.cards, cursor: "c0"))
        await store.refreshSnapshot(board: "ops")
        #expect(store.session == before)

        let changedCards = [KanbanJSON.card("t1", title: "Ship the cache"), KanbanJSON.card("t2", status: "done", title: "Fix the title")]
        script.enqueue("kanban.board.snapshot", KanbanJSON.snapshot(changedCards, cursor: "c1"))
        await store.refreshSnapshot(board: "ops")
        let rows = try #require(store.visibleRows(board: "ops"))
        let old = before.cache("ops")?.cards ?? [:]
        let changed = rows.filter { old[$0.card.cardID] != $0.card }.map(\.card.taskID)
        #expect(changed == ["t2"])
        #expect(titles(rows) == ["t1": "Ship the cache", "t2": "Fix the title"])
    }

    @Test("a schema bump, an expired file and a corrupt file are dropped without a crash, then rebuilt")
    func invalidFilesAreDropped() async throws {
        _ = await warmed()
        let expired = disk(now: Date().addingTimeInterval(KanbanSavedBoard.maxAge + 60))
        #expect(await expired.load(board: "ops") == nil)
        cache.drain()
        #expect(!FileManager.default.fileExists(atPath: url.path))

        _ = await warmed()
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var payload = try #require(json["payload"] as? [String: Any])
        payload["schema"] = KanbanSavedBoard.currentSchema + 1
        json["payload"] = payload
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        #expect(await disk().load(board: "ops") == nil)

        try Data("not json".utf8).write(to: url)
        #expect(await disk().load(board: "ops") == nil)
        _ = await warmed()
        #expect(await disk().load(board: "ops") != nil)
    }

    @Test("the saved file holds only fields the read types decode")
    func savedFileHoldsNoSecrets() async throws {
        _ = await warmed()
        let text = try String(contentsOf: url, encoding: .utf8)
        for word in ["token", "password", "secret", "credential", "authorization"] {
            #expect(!text.lowercased().contains(word), "\(word)")
        }
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let payload = try #require(json["payload"] as? [String: Any])
        #expect(Set(payload.keys) == ["schema", "savedAt", "gatewayID", "cache", "details"])
        let cards = try #require((payload["cache"] as? [String: Any])?["cards"] as? [String: [String: Any]])
        let cardKeys = Set(cards.values.flatMap(\.keys))
        #expect(cardKeys.isSubset(of: ["cardID", "taskID", "title", "status", "assignee", "priority", "createdAt", "startedAt", "completedAt", "blockKind", "governed"]))
    }
}
