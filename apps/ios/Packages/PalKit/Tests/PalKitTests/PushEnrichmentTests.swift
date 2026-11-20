import Foundation
@testable import PalPush
import Testing

@Suite("A push becomes a bot-avatar notification only when it can do so whole")
struct PushEnrichmentTests {
    private static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])
    private static var userInfo: [AnyHashable: Any] { ["profile": "hermes-bot-mobile", "session_id": "s-1"] }

    private func cache() throws -> PushAvatarCache {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("push-avatars-\(UUID().uuidString)")
        return PushAvatarCache(directory: directory)
    }

    @Test("a cached avatar and a display name make the enrichment")
    func complete() throws {
        let cache = try cache()
        #expect(cache.store(Self.png, for: "hermes-bot-mobile"))
        let enrichment = try #require(PushEnrichment(
            userInfo: Self.userInfo, title: "  Memolly ", body: "Finished", cache: cache
        ))
        #expect(enrichment.sender.profile == "hermes-bot-mobile")
        #expect(enrichment.sender.displayName == "Memolly")
        #expect(enrichment.sender.body == "Finished")
        #expect(enrichment.avatar == Self.png)
    }

    @Test("no cached avatar leaves the notification as it came")
    func noAvatar() throws {
        #expect(PushEnrichment(userInfo: Self.userInfo, title: "Memolly", body: "Finished", cache: try cache()) == nil)
    }

    @Test("no app group container leaves the notification as it came")
    func noCache() {
        #expect(PushEnrichment(userInfo: Self.userInfo, title: "Memolly", body: "Finished", cache: nil) == nil)
    }

    @Test("a payload without a usable profile or a title is not enriched", arguments: [
        ("", "Memolly"),
        ("../etc", "Memolly"),
        (String(repeating: "a", count: 65), "Memolly"),
        ("memolly", "   "),
    ])
    func unusable(profile: String, title: String) throws {
        let cache = try cache()
        cache.store(Self.png, for: "memolly")
        #expect(PushEnrichment(userInfo: ["profile": profile], title: title, body: "x", cache: cache) == nil)
    }

    @Test("a payload with no profile or a non-text profile is not enriched")
    func missingProfile() throws {
        let cache = try cache()
        cache.store(Self.png, for: "memolly")
        #expect(PushEnrichment(userInfo: [:], title: "Memolly", body: "x", cache: cache) == nil)
        #expect(PushEnrichment(userInfo: ["profile": 7], title: "Memolly", body: "x", cache: cache) == nil)
    }
}

@Suite("The avatar cache the app writes and the extension reads")
struct PushAvatarCacheTests {
    private static let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3, 4])

    private func cache() -> PushAvatarCache {
        PushAvatarCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("push-cache-\(UUID().uuidString)"))
    }

    @Test("a stored picture reads back and a rewrite replaces it")
    func roundTrip() {
        let cache = cache()
        #expect(cache.image(for: "atlas") == nil)
        #expect(cache.store(Self.png, for: "atlas"))
        #expect(cache.image(for: "atlas") == Self.png)
        let next = Data([0x89, 0x50, 9, 9])
        #expect(cache.store(next, for: "atlas"))
        #expect(cache.image(for: "atlas") == next)
    }

    @Test("a profile id never leaves the cache directory")
    func pathSafety() throws {
        let cache = cache()
        let url = try #require(cache.url(for: "../../outside"))
        #expect(url.deletingLastPathComponent() == cache.directory)
        #expect(cache.url(for: "") == nil)
    }

    @Test("empty and oversized pictures are refused and read as absent")
    func limits() throws {
        let cache = cache()
        #expect(!cache.store(Data(), for: "atlas"))
        #expect(!cache.store(Data(count: PushAvatarCache.maximumFileBytes + 1), for: "atlas"))
        #expect(cache.image(for: "atlas") == nil)
        let url = try #require(cache.url(for: "huge"))
        try FileManager.default.createDirectory(at: cache.directory, withIntermediateDirectories: true)
        try Data(count: PushAvatarCache.maximumFileBytes + 1).write(to: url)
        #expect(cache.image(for: "huge") == nil)
    }

    @Test("pruning keeps the listed bots and drops the rest")
    func prune() {
        let cache = cache()
        for name in ["a", "b", "c"] { cache.store(Self.png, for: name) }
        cache.prune(keeping: ["a", "c"])
        #expect(cache.image(for: "a") != nil && cache.image(for: "c") != nil)
        #expect(cache.image(for: "b") == nil)
    }

    @Test("a build without the app group has no cache, so the push stays the plain alert")
    func withoutAppGroup() {
        #expect(PushAvatarCache.shared(fileManager: GrouplessFileManager()) == nil)
        let enrichment = PushEnrichment(
            userInfo: ["profile": "atlas"], title: "Atlas", body: "Done",
            cache: PushAvatarCache.shared(fileManager: GrouplessFileManager())
        )
        #expect(enrichment == nil)
    }

    @Test("a build with the app group keeps its avatars inside the group container")
    func withAppGroup() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("group-\(UUID().uuidString)")
        let cache = PushAvatarCache.shared(fileManager: GroupContainerFileManager(root: root))
        #expect(cache?.directory.deletingLastPathComponent().path == root.path)
    }
}

private final class GrouplessFileManager: FileManager, @unchecked Sendable {
    override func containerURL(forSecurityApplicationGroupIdentifier groupIdentifier: String) -> URL? { nil }
}

private final class GroupContainerFileManager: FileManager, @unchecked Sendable {
    private let root: URL

    init(root: URL) {
        self.root = root
        super.init()
    }

    override func containerURL(forSecurityApplicationGroupIdentifier groupIdentifier: String) -> URL? {
        groupIdentifier == PushAvatarCache.groupIdentifier ? root : nil
    }
}
