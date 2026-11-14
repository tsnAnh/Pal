import Foundation
import PalBotProfile
import PalProtocol
import Testing

@Suite("Surface cache")
@MainActor
struct SurfaceCacheTests {
    private struct Payload: Codable, Sendable, Equatable {
        var text: String
    }

    private let store = CacheStore(
        root: FileManager.default.temporaryDirectory.appending(path: "surface-\(UUID().uuidString)", directoryHint: .isDirectory)
    )

    private func cache(account: String = "a|me") -> SurfaceCache {
        SurfaceCache(store: store, account: { account })
    }

    @Test func persistedValuesSurviveANewSessionButRememberedOnesDoNot() async {
        let key = SurfaceKey.screen("routines", bot: "atlas")
        let secret = SurfaceKey.screen("vault")
        let first = cache()
        first.persist(Payload(text: "kept"), key)
        first.remember(Payload(text: "memory only"), secret)

        let second = cache()
        #expect(second.remembered(Payload.self, key) == nil)
        #expect(await second.value(Payload.self, key) == Payload(text: "kept"))
        #expect(second.remembered(Payload.self, key) == Payload(text: "kept"))
        #expect(await second.value(Payload.self, secret) == nil)
    }

    @Test func valuesStayWithTheirAccountAndBot() async {
        let mine = cache()
        mine.persist(Payload(text: "atlas"), .screen("persona", bot: "atlas"))

        #expect(await cache(account: "a|other").value(Payload.self, .screen("persona", bot: "atlas")) == nil)
        #expect(await mine.value(Payload.self, .screen("persona", bot: "orion")) == nil)
    }

    @Test func signingOutDropsWhatWasHeldInMemory() {
        let held = cache()
        held.remember(Payload(text: "x"), .screen("vault"))
        held.forgetAll()
        #expect(held.remembered(Payload.self, .screen("vault")) == nil)
    }

    @Test func forgettingAKeyRemovesItFromDiskToo() async {
        let key = SurfaceKey.screen("library-all", bot: "atlas")
        let first = cache()
        first.persist(Payload(text: "page"), key)
        first.forget(key)
        #expect(await cache().value(Payload.self, key) == nil)
    }

    @Test func voiceAndMemorySettingsSurviveTheRoundTripThroughTheCache() async throws {
        let wire = """
        {"tts":{"selected":"edge","providers":[{"id":"edge","name":"Edge","key_name":"EDGE_KEY","key_required":true,"key_set":true,"can_remove":true,"ready":true,"selectable":true,"note":"ok"}],"voice":{"current":"a","options":[{"id":"a","label":"A"}]}},"memory":{"selected":"","providers":[]}}
        """
        let decoded = try JSONDecoder().decode(SpeechMemorySettings.self, from: Data(wire.utf8))
        let key = SurfaceKey.screen("speech-memory", bot: "atlas")
        cache().persist(decoded, key)
        #expect(await cache().value(SpeechMemorySettings.self, key) == decoded)
    }

    @Test func modelOverviewRowsSurviveTheRoundTripThroughTheCache() async {
        let rows = [
            BotModelsRow(
                name: "atlas", displayName: "Atlas", chat: BotModelReading(model: "gpt", effort: "high"),
                cloud: BotModelReading(model: nil, effort: nil))
        ]
        let key = SurfaceKey.screen("bot-models-overview")
        cache().persist(rows, key)
        #expect(await cache().value([BotModelsRow].self, key) == rows)
    }
}
