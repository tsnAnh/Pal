import Foundation
import Testing

@testable import PalBotProfile
@testable import PalProtocol
@testable import PalTransport

private func provider(
    _ id: String, key: String? = nil, required: Bool = false, set: Bool = false, canRemove: Bool = false,
    selectable: Bool = true
) -> JSONValue {
    var object: [String: JSONValue] = [
        "id": .string(id), "name": .string(id.capitalized), "key_required": .bool(required), "key_set": .bool(set),
        "can_remove": .bool(canRemove), "ready": .bool(set), "selectable": .bool(selectable),
    ]
    if let key { object["key_name"] = .string(key) }
    return .object(object)
}

private func snapshot(
    ttsSelected: String = "edge", elevenSet: Bool = false, memorySelected: String = "", retainSet: Bool = false
) -> JSONValue {
    [
        "profile": "atlas",
        "tts": [
            "selected": .string(ttsSelected),
            "providers": [
                provider("edge", set: true),
                provider("elevenlabs", key: "ELEVENLABS_API_KEY", required: true, set: elevenSet, canRemove: elevenSet),
            ],
            "voice": ["current": "en-US-AriaNeural", "options": [["id": "en-US-AriaNeural", "label": "English (US) — Aria"]]],
        ],
        "memory": [
            "selected": .string(memorySelected),
            "providers": [provider("retaindb", key: "RETAINDB_API_KEY", required: true, set: retainSet, canRemove: retainSet)],
        ],
    ]
}

private func reply(_ outcome: String, reason: String? = nil, settings: JSONValue? = nil) -> JSONValue {
    var object: [String: JSONValue] = ["outcome": .string(outcome)]
    if let reason { object["reason"] = .string(reason) }
    if let settings { object["settings"] = settings }
    return .object(object)
}

@Suite("Speech and memory client")
struct SpeechMemoryClientTests {
    private func client(_ bots: ScriptedBots) -> SpeechMemoryClient {
        SpeechMemoryClient(gateway: bots.gateway, profile: "atlas")
    }

    @Test("settings decodes status, voices and the missing fields")
    func decodes() async throws {
        let bots = ScriptedBots()
        bots.script("speech_memory.settings.get", snapshot(elevenSet: true))
        let settings = try await client(bots).settings()
        #expect(bots.calls.first?.params == ["profile": "atlas"])
        let eleven = try #require(settings.tts.providers.last)
        #expect(eleven.keyName == "ELEVENLABS_API_KEY" && eleven.keySet && eleven.canRemove && eleven.statusWord == "Set")
        #expect(settings.tts.providers.first?.keyName == nil)
        #expect(settings.tts.voice?.options.first?.id == "en-US-AriaNeural")
        #expect(settings.memory.providers.first?.statusWord == "Not set")
        #expect(settings.memory.voice == nil)
    }

    @Test("choose maps every outcome and sends the area, provider and voice")
    func chooseOutcomes() async {
        let expected: [(String, SpeechMemoryChoice)] = [
            ("saved", .saved(nil)), ("needs_key", .needsKey("Add its key first.")),
            ("unsupported", .unsupported("Add its key first.")), ("invalid", .invalid("Add its key first.")),
            ("failed", .failed("Add its key first.")),
        ]
        for (wire, result) in expected {
            let bots = ScriptedBots()
            bots.script("speech_memory.settings.set", reply(wire, reason: "Add its key first."))
            #expect(await client(bots).choose(.tts, provider: "edge", voice: "en-US-AriaNeural") == result)
            #expect(bots.calls.first?.params == ["profile": "atlas", "area": "tts", "provider": "edge", "voice": "en-US-AriaNeural"])
        }
        let broken = ScriptedBots()
        broken.script("speech_memory.settings.set") { _ in throw GatewayTransportError.closed(.normal) }
        #expect(await client(broken).choose(.memory, provider: "") == .failed(SpeechMemoryClient.couldNotSave))
    }

    @Test("keys travel through capabilities.set_key, set with a value and removed with null")
    func keysUseTheCapabilitiesMethod() async throws {
        let bots = ScriptedBots()
        bots.script("capabilities.set_key", ["profile": "atlas", "key_name": "RETAINDB_API_KEY", "is_set": true, "capabilities": []])
        try await client(bots).setKey("RETAINDB_API_KEY", to: SecretString("canary-value"))
        try await client(bots).removeKey("RETAINDB_API_KEY")
        let calls = bots.calls(to: "capabilities.set_key")
        #expect(calls.map(\.params["key_name"]) == ["RETAINDB_API_KEY", "RETAINDB_API_KEY"])
        #expect(calls.map(\.params["value"]) == ["canary-value", .null])
        #expect(bots.calls.allSatisfy { $0.method == "capabilities.set_key" })
    }
}

@MainActor
@Suite("Speech and memory model")
struct SpeechMemoryModelTests {
    private func model(_ bots: ScriptedBots) -> SpeechMemoryModel {
        SpeechMemoryModel(client: SpeechMemoryClient(gateway: bots.gateway, profile: "atlas"))
    }

    private func target(_ model: SpeechMemoryModel, _ area: SpeechMemoryArea, _ id: String) throws -> SpeechMemoryModel.Target {
        let provider = try #require(model.settings?.group(area).providers.first { $0.id == id })
        return SpeechMemoryModel.Target(area: area, provider: provider)
    }

    @Test("load shows settings, and a failed first load is reported")
    func load() async {
        let bots = ScriptedBots()
        bots.script("speech_memory.settings.get", snapshot())
        let loaded = model(bots)
        await loaded.load()
        #expect(loaded.hasLoaded && !loaded.loadFailed)
        let broken = ScriptedBots()
        broken.script("speech_memory.settings.get") { _ in throw GatewayTransportError.closed(.normal) }
        let failed = model(broken)
        await failed.load()
        #expect(!failed.hasLoaded && failed.loadFailed)
    }

    @Test("saving a key closes the entry, refreshes the status and never keeps the value")
    func saveKey() async throws {
        let bots = ScriptedBots()
        bots.script("speech_memory.settings.get", snapshot())
        bots.script("speech_memory.settings.get", snapshot(elevenSet: true))
        bots.script("capabilities.set_key", ["profile": "atlas", "key_name": "ELEVENLABS_API_KEY", "is_set": true, "capabilities": []])
        let model = model(bots)
        await model.load()
        model.beginKeyEntry(try target(model, .tts, "elevenlabs"))
        await model.submitKey("  canary-value \n")
        #expect(bots.calls(to: "capabilities.set_key").first?.params["value"] == "canary-value")
        #expect(model.keyEntry == nil && model.keyEntryState == .idle)
        #expect(model.settings?.tts.providers.last?.keySet == true)
        #expect(model.status(.tts, "elevenlabs") == .succeeded("Key saved."))
    }

    @Test("a failed save keeps the entry open with a failure and the old status")
    func saveKeyFails() async throws {
        let bots = ScriptedBots()
        bots.script("speech_memory.settings.get", snapshot())
        bots.script("capabilities.set_key") { _ in throw GatewayTransportError.closed(.normal) }
        let model = model(bots)
        await model.load()
        model.beginKeyEntry(try target(model, .tts, "elevenlabs"))
        await model.submitKey("canary-value")
        #expect(model.keyEntry != nil)
        guard case .failed = model.keyEntryState else { Issue.record("expected a failure"); return }
        #expect(model.settings?.tts.providers.last?.keySet == false)
        await model.submitKey("   ")
        #expect(model.keyEntryState == .failed("Paste a key to save."))
        #expect(bots.calls(to: "capabilities.set_key").count == 1)
    }

    @Test("a provider without a key name has no key entry")
    func noKeyEntry() async throws {
        let bots = ScriptedBots()
        bots.script("speech_memory.settings.get", snapshot())
        let model = model(bots)
        await model.load()
        model.beginKeyEntry(try target(model, .tts, "edge"))
        #expect(model.keyEntry == nil)
    }

    @Test("remove sends null, refreshes, and reports success only when the key is gone")
    func remove() async throws {
        let bots = ScriptedBots()
        bots.script("speech_memory.settings.get", snapshot(elevenSet: true))
        bots.script("speech_memory.settings.get", snapshot(elevenSet: false))
        bots.script("capabilities.set_key", ["profile": "atlas", "key_name": "ELEVENLABS_API_KEY", "is_set": false, "capabilities": []])
        let model = model(bots)
        await model.load()
        let eleven = try target(model, .tts, "elevenlabs")
        model.pendingRemoval = eleven
        await model.remove(eleven)
        #expect(model.pendingRemoval == nil)
        #expect(bots.calls(to: "capabilities.set_key").first?.params["value"] == .null)
        #expect(model.status(.tts, "elevenlabs") == .succeeded("Key removed."))

        let shared = ScriptedBots()
        shared.script("speech_memory.settings.get", snapshot(elevenSet: true))
        shared.script("capabilities.set_key", ["profile": "atlas", "key_name": "ELEVENLABS_API_KEY", "is_set": false, "capabilities": []])
        let still = self.model(shared)
        await still.load()
        await still.remove(try target(still, .tts, "elevenlabs"))
        guard case .failed = still.status(.tts, "elevenlabs") else { Issue.record("expected a failure"); return }
    }

    @Test("a failed removal keeps the key and says so")
    func removeFails() async throws {
        let bots = ScriptedBots()
        bots.script("speech_memory.settings.get", snapshot(elevenSet: true))
        bots.script("capabilities.set_key") { _ in throw GatewayTransportError.closed(.normal) }
        let model = model(bots)
        await model.load()
        await model.remove(try target(model, .tts, "elevenlabs"))
        #expect(model.status(.tts, "elevenlabs") == .failed("Couldn't remove the key. It was kept."))
        #expect(model.settings?.tts.providers.last?.keySet == true)
    }

    @Test("choosing applies the gateway's snapshot, and a refusal leaves the choice unchanged")
    func choose() async {
        let bots = ScriptedBots()
        bots.script("speech_memory.settings.get", snapshot())
        bots.script("speech_memory.settings.set", reply("needs_key", reason: "Add its key first."))
        bots.script("speech_memory.settings.set", reply("saved", settings: snapshot(ttsSelected: "elevenlabs", elevenSet: true)))
        let model = model(bots)
        await model.load()
        await model.choose(.tts, provider: "elevenlabs")
        #expect(model.choice(.tts) == .failed("Add its key first."))
        #expect(model.settings?.tts.selected == "edge")
        await model.choose(.tts, provider: "elevenlabs")
        #expect(model.settings?.tts.selected == "elevenlabs")
        guard case .succeeded = model.choice(.tts) else { Issue.record("expected success"); return }
        await model.choose(.tts, provider: "elevenlabs")
        #expect(bots.calls(to: "speech_memory.settings.set").count == 2)
    }
}
