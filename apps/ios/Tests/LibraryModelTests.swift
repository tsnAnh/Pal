import Foundation
import PalBotProfile
import PalProtocol
import Synchronization
import Testing

@testable import HermesBots

private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let released = waiters
        waiters = []
        for waiter in released { waiter.resume() }
    }
}

private final class Counter: Sendable {
    private let count = Mutex(0)

    func next() -> Int {
        count.withLock { value in
            value += 1
            return value
        }
    }
}

private struct Request: Equatable {
    let kind: String
    let before: String?
}

private final class ScriptedLibrary: Sendable {
    typealias Reply = @Sendable (Request) async throws -> JSONValue

    private let log = Mutex<[Request]>([])
    private let reply: Reply

    init(_ reply: @escaping Reply) {
        self.reply = reply
    }

    var requests: [Request] { log.withLock { $0 } }

    var service: LibraryService {
        LibraryService(gateway: BotsGateway { [self] _, params in
            let object = params?.objectValue ?? [:]
            let request = Request(kind: object["kind"]?.stringValue ?? "", before: object["before"]?.stringValue)
            log.withLock { $0.append(request) }
            return try await reply(request)
        })
    }
}

private struct Offline: Error {}

private let newest = Date(timeIntervalSince1970: 1_800_000_000)

private func stamp(_ index: Int) -> String {
    ISO8601DateFormatter().string(from: newest.addingTimeInterval(TimeInterval(-index)))
}

private func page(_ indices: [Int], next: Int?, complete: Bool = true) -> JSONValue {
    let items: [JSONValue] = indices.map { index in
        [
            "id": .string("item-\(index)"), "kind": "link", "title": .string("example.com/\(index)"), "subtitle": "example.com",
            "url": .string("https://example.com/\(index)"), "asset_ref": .null, "mime": .null, "size": .null,
            "session_id": "s1", "occurred_at": .string(stamp(index)),
        ]
    }
    return ["items": .array(items), "next_before": next.map { .string(stamp($0)) } ?? .null, "index_complete": .bool(complete)]
}

@MainActor
private func makeModel(_ library: ScriptedLibrary, pollInterval: Duration = LibraryModel.defaultPollInterval) -> LibraryModel {
    let root = FileManager.default.temporaryDirectory.appending(path: "library-model-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    let surfaces = SurfaceCache(store: CacheStore(root: root), account: { "test|me" })
    return LibraryModel(botName: "bot", library: library.service, surfaces: surfaces, pollInterval: pollInterval)
}

@MainActor
private func settles(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<500 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

@MainActor
@Suite("Library model")
struct LibraryModelTests {
    @Test func aFilterChangeDuringLoadMoreDoesNotBlockLaterPagination() async {
        let held = Gate()
        let library = ScriptedLibrary { request in
            switch (request.kind, request.before) {
            case ("all", nil): return page(Array(0..<50), next: 49)
            case ("all", _):
                await held.wait()
                return page(Array(50..<100), next: nil)
            case (_, nil): return page(Array(1000..<1050), next: 1049)
            default: return page(Array(1050..<1100), next: nil)
            }
        }
        let model = makeModel(library)
        model.start()
        #expect(await settles { model.phase == .ready && model.entries.count == 50 })
        model.loadMore()
        #expect(await settles { library.requests.count == 2 })
        model.filter = .links
        #expect(await settles { model.phase == .ready && model.entries.first?.id == "item-1000" })
        await held.open()
        model.loadMore()
        #expect(await settles { model.entries.count == 100 })
        #expect(model.entries.last?.id == "item-1099")
        #expect(library.requests.last == Request(kind: "links", before: stamp(1049)))
    }

    @Test func pollingWhileIndexingKeepsThePagesTheOwnerAlreadyLoaded() async {
        let held = Gate()
        let firstPages = Counter()
        let library = ScriptedLibrary { request in
            if request.before == nil {
                let served = firstPages.next()
                if served == 1 { return page(Array(0..<50), next: 49, complete: false) }
                await held.wait()
                return page([-1] + Array(0..<49), next: 48)
            }
            return request.before == stamp(49) ? page(Array(50..<100), next: 99, complete: false) : page(Array(100..<150), next: nil)
        }
        let model = makeModel(library, pollInterval: .milliseconds(20))
        model.start()
        #expect(await settles { model.phase == .ready && model.entries.count == 50 })
        model.loadMore()
        #expect(await settles { model.entries.count == 100 })
        await held.open()
        #expect(await settles { !model.isIndexing })
        #expect(model.entries.count == 101)
        #expect(model.entries.first?.id == "item--1")
        #expect(model.entries.last?.id == "item-99")
        model.loadMore()
        #expect(await settles { model.entries.count == 151 })
        #expect(library.requests.last == Request(kind: "all", before: stamp(99)))
    }

    @Test func aFailedNextPageWaitsForTheOwnerThenRetryAppendsIt() async {
        let outage = Mutex(true)
        let library = ScriptedLibrary { request in
            if request.before == nil { return page(Array(0..<50), next: 49) }
            if outage.withLock({ $0 }) { throw Offline() }
            return page(Array(50..<100), next: nil)
        }
        let model = makeModel(library)
        model.start()
        #expect(await settles { model.phase == .ready && model.entries.count == 50 })
        model.loadMore()
        #expect(await settles { model.pagination == .failed(cursor: stamp(49)) })
        #expect(model.hasMore)
        #expect(model.entries.count == 50)
        model.loadMore()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(model.pagination == .failed(cursor: stamp(49)))
        #expect(library.requests.count == 2)
        outage.withLock { $0 = false }
        model.retryLoadMore()
        #expect(model.pagination == .loading(cursor: stamp(49), trigger: .retry))
        #expect(await settles { model.entries.count == 100 })
        #expect(model.pagination == .end)
        #expect(library.requests.last == Request(kind: "all", before: stamp(49)))
    }

    @Test func aRetryThatFailsAgainKeepsTheSameCursorAndTheNextRetrySucceeds() async {
        let attempts = Counter()
        let library = ScriptedLibrary { request in
            if request.before == nil { return page(Array(0..<50), next: 49) }
            if attempts.next() < 3 { throw Offline() }
            return page(Array(50..<100), next: nil)
        }
        let model = makeModel(library)
        model.start()
        #expect(await settles { model.phase == .ready && model.entries.count == 50 })
        model.loadMore()
        #expect(await settles { model.pagination == .failed(cursor: stamp(49)) })
        model.retryLoadMore()
        #expect(await settles { library.requests.count == 3 })
        #expect(await settles { model.pagination == .failed(cursor: stamp(49)) })
        model.retryLoadMore()
        #expect(await settles { model.entries.count == 100 })
        #expect(model.pagination == .end)
    }
}
