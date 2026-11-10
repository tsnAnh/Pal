import Foundation
import HermesChat
import HermesProtocol
import HermesRoster
import Testing

@Suite("Local cache")
struct LocalCacheTests {
    private struct Payload: Codable, Sendable, Equatable {
        var text: String
    }

    private func makeStore(maxFileBytes: Int = CacheStore.defaultMaxFileBytes) -> CacheStore {
        CacheStore(
            root: FileManager.default.temporaryDirectory.appending(path: "cache-\(UUID().uuidString)", directoryHint: .isDirectory),
            maxFileBytes: maxFileBytes
        )
    }

    private func file(_ store: CacheStore, name: String, account: String) -> URL {
        store.fileURL(name: name, account: account)
    }

    @Test func roundTripsPerAccountWithoutLeaking() {
        let store = makeStore()
        store.save(Payload(text: "mine"), name: "roster", account: "a|me")
        #expect(store.load(Payload.self, name: "roster", account: "a|me") == Payload(text: "mine"))
        #expect(store.load(Payload.self, name: "roster", account: "a|other") == nil)
    }

    @Test func corruptFileIsDiscarded() throws {
        let store = makeStore()
        store.save(Payload(text: "x"), name: "roster", account: "acct")
        store.drain()
        let url = file(store, name: "roster", account: "acct")
        try Data("{not json".utf8).write(to: url)
        #expect(store.load(Payload.self, name: "roster", account: "acct") == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func foreignFormatVersionIsDiscarded() throws {
        let store = makeStore()
        store.save(Payload(text: "x"), name: "roster", account: "acct")
        store.drain()
        let url = file(store, name: "roster", account: "acct")
        try Data(#"{"version":99,"payload":{"text":"x"}}"#.utf8).write(to: url)
        #expect(store.load(Payload.self, name: "roster", account: "acct") == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func oversizedWritesAreSkippedAndOversizedFilesDiscarded() throws {
        let store = makeStore(maxFileBytes: 200)
        store.save(Payload(text: String(repeating: "a", count: 500)), name: "big", account: "acct")
        store.drain()
        #expect(!FileManager.default.fileExists(atPath: file(store, name: "big", account: "acct").path))

        let generous = CacheStore(root: store.root)
        generous.save(Payload(text: String(repeating: "a", count: 500)), name: "big", account: "acct")
        generous.drain()
        #expect(store.load(Payload.self, name: "big", account: "acct") == nil)
        #expect(!FileManager.default.fileExists(atPath: file(store, name: "big", account: "acct").path))
    }

    @Test func removeAllExceptKeepsOnlyTheActiveAccount() {
        let store = makeStore()
        store.save(Payload(text: "keep"), name: "roster", account: "keep")
        store.save(Payload(text: "drop"), name: "roster", account: "drop")
        store.removeAll(except: "keep")
        store.drain()
        #expect(store.load(Payload.self, name: "roster", account: "keep") != nil)
        #expect(store.load(Payload.self, name: "roster", account: "drop") == nil)
        store.removeAll()
        store.drain()
        #expect(store.load(Payload.self, name: "roster", account: "keep") == nil)
    }

    @Test func pruneRemovesOnlyUnlistedConversations() {
        let store = makeStore()
        for bot in ["alpha", "gone"] {
            store.save(Payload(text: bot), name: CachedTranscript.cacheName(forBot: bot), account: "acct")
        }
        store.save(Payload(text: "roster"), name: "roster", account: "acct")
        store.prune(account: "acct", prefix: CachedTranscript.namePrefix, keeping: [CachedTranscript.cacheName(forBot: "alpha")])
        store.drain()
        #expect(store.load(Payload.self, name: CachedTranscript.cacheName(forBot: "alpha"), account: "acct") != nil)
        #expect(store.load(Payload.self, name: CachedTranscript.cacheName(forBot: "gone"), account: "acct") == nil)
        #expect(store.load(Payload.self, name: "roster", account: "acct") != nil)
    }

    @Test func rosterCacheDropsFieldsItDoesNotNeed() throws {
        let profile: JSONValue = [
            "name": "alpha",
            "display_name": "Alpha",
            "is_primary": true,
            "api_key": "secret-value",
            "ui_meta": ["hermes-bots": ["pinned": true], "other": ["token": "secret"]],
            "canonical_session": ["id": "s1", "preview": "hi", "last_active": 5, "internal_path": "/tmp/x"],
        ]
        let snapshot = RosterSnapshot(profiles: [profile, ["display_name": "nameless"]], live: [:], receivedAt: Date())
        let entry = RosterCache.entry(from: snapshot, photos: ["alpha": Data([1]), "ghost": Data([2])])
        #expect(entry.profiles.count == 1)
        let encoded = String(decoding: try JSONEncoder().encode(entry), as: UTF8.self)
        #expect(!encoded.contains("secret"))
        #expect(!encoded.contains("internal_path"))
        #expect(entry.photos.keys.sorted() == ["alpha"])
        let restored = entry.profiles.compactMap(RosterProfile.init)
        #expect(restored.first?.botMeta.isPinned == true)
        #expect(restored.first?.canonical?.preview == "hi")
    }

    @Test func rosterCacheDropsOversizedPhotos() {
        let snapshot = RosterSnapshot(profiles: [["name": "alpha"]], live: [:], receivedAt: Date())
        let entry = RosterCache.entry(from: snapshot, photos: ["alpha": Data(count: RosterCache.maxPhotoBytes + 1)])
        #expect(entry.photos.isEmpty)
    }

    @Test func conversationCacheKeepsOnlySettledMessagesNewestFirstWithinBounds() throws {
        let sender = BotSender(name: "Beta", handle: "beta")
        let items: [TranscriptItem] = [
            TranscriptItem(id: "row:1", content: .user(text: "one", delivery: .sent), timestamp: Date(timeIntervalSince1970: 1)),
            TranscriptItem(id: "row:2", content: .assistant(text: "two", reasoning: "", isStreaming: false), timestamp: Date(timeIntervalSince1970: 2)),
            TranscriptItem(id: "row:3", content: .user(text: "Message from 🤖 Beta (@beta): hi", delivery: .sent), inbound: .botMessage(sender, body: "hi")),
            TranscriptItem(id: "stream:t:0", content: .assistant(text: "typing", reasoning: "", isStreaming: true)),
            TranscriptItem(id: "submission:x", content: .user(text: "pending", delivery: .queued)),
        ]
        let cached = try #require(CachedTranscript(sessionID: "s1", items: items, date: { _ in Date(timeIntervalSince1970: 9) }))
        let restored = cached.transcriptItems
        #expect(restored.map(\.id) == ["row:1", "row:2", "row:3"])
        #expect(restored[2].inbound == .botMessage(sender, body: "hi"))
        #expect(restored[2].timestamp == Date(timeIntervalSince1970: 9))
        let decoded = try JSONDecoder().decode(CachedTranscript.self, from: JSONEncoder().encode(cached))
        #expect(decoded == cached)

        let bounded = try #require(CachedTranscript(sessionID: "s1", items: items, date: { _ in nil }, maxItems: 2))
        #expect(bounded.transcriptItems.map(\.id) == ["row:2", "row:3"])
        #expect(CachedTranscript(sessionID: nil, items: items, date: { _ in nil }) == nil)
        #expect(CachedTranscript(sessionID: "s1", items: [], date: { _ in nil }) == nil)
    }
}
