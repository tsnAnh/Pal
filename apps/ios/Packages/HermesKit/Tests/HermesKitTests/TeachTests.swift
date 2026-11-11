import Foundation
import HermesBotProfile
import HermesProtocol
import HermesTransport
import Testing

private func status(
    available: Bool = true,
    recording: Bool = false,
    capture: String = "idle",
    ended: String? = nil,
    deadlineAt: Double? = nil,
    now: Double = 1000,
    pending: JSONValue = .null
) -> JSONValue {
    var wire: [String: JSONValue] = [
        "available": .bool(available),
        "max_seconds": 600,
        "now": .double(now),
        "recording": .bool(recording),
        "capture": .string(capture),
        "event_count": 0,
        "truncated": false,
        "pending": pending,
    ]
    if let ended { wire["ended"] = .string(ended) }
    if let deadlineAt { wire["deadline_at"] = .double(deadlineAt) }
    return .object(wire)
}

private func pending(state: String) -> JSONValue {
    ["teach_id": "t1", "skill_name": "file-expenses", "event_count": 12, "truncated": false, "state": .string(state)]
}

private func draft(
    state: String = "ready",
    content: JSONValue = "# Skill",
    hash: JSONValue = "h1",
    extraFiles: JSONValue = []
) -> JSONValue {
    [
        "teach_id": "t1", "skill_name": "file-expenses", "event_count": 12, "truncated": false,
        "state": .string(state), "content": content, "content_hash": hash, "extra_files": extraFiles,
    ]
}

private func refusal(_ code: String) -> GatewayTransportError {
    .rpc(RPCError(code: 5310, message: "refused", data: ["code": .string(code)]))
}

private func service(_ bots: ScriptedBots, now: Double = 1000) -> TeachService {
    TeachService(gateway: bots.gateway, clock: { now })
}

@Suite("Bot teach mode")
struct TeachTests {
    @Test("status asks this bot's profile and decodes an idle, teachable bot")
    func idle() async throws {
        let bots = ScriptedBots()
        bots.script("bot.teach.status", status())
        let snapshot = try await service(bots).status(for: "cho-ua")
        #expect(bots.calls(to: "bot.teach.status").first?.params["profile"] == "cho-ua")
        #expect(snapshot.phase(live: true) == .idle)
        #expect(snapshot.pollDelay == nil)
    }

    @Test("the screen not being live hides teaching whatever the gateway says")
    func notLive() async throws {
        let bots = ScriptedBots()
        bots.script("bot.teach.status", status(recording: true))
        #expect(try await service(bots).status(for: "b").phase(live: false) == .hidden)
    }

    @Test("a bot that cannot be taught shows nothing")
    func unavailable() async throws {
        let bots = ScriptedBots()
        bots.script("bot.teach.status", status(available: false))
        #expect(try await service(bots).status(for: "b").phase(live: true) == .hidden)
    }

    @Test("a recording counts down on the gateway clock, not the device clock")
    func countdownUsesGatewayClock() async throws {
        let bots = ScriptedBots()
        bots.script("bot.teach.status", status(recording: true, capture: "waiting", deadlineAt: 1600, now: 1000))
        let snapshot = try await service(bots, now: 5000).status(for: "b")
        #expect(snapshot.phase(live: true) == .recording)
        #expect(snapshot.waitingForBrowser)
        #expect(snapshot.secondsLeft(at: 5000) == 600)
        #expect(snapshot.secondsLeft(at: 5090.2) == 510)
        #expect(snapshot.secondsLeft(at: 9000) == 0)
        #expect(snapshot.pollDelay == TeachSnapshot.recordingPoll)
        #expect(TeachSnapshot.clock(510) == "8:30")
    }

    @Test("an unresolved draft outranks idle and polls only while the bot is still writing")
    func pendingDraft() async throws {
        let bots = ScriptedBots()
        bots.script("bot.teach.status", status(pending: pending(state: "drafting")))
        bots.script("bot.teach.status", status(pending: pending(state: "ready")))
        let writing = try await service(bots).status(for: "b")
        #expect(writing.phase(live: true) == .drafting)
        #expect(writing.pollDelay == TeachSnapshot.draftingPoll)
        let ready = try await service(bots).status(for: "b")
        #expect(ready.phase(live: true) == .ready)
        #expect(ready.pending?.teachID == "t1")
        #expect(ready.pollDelay == nil)
    }

    @Test("a recording that ended on its own awaits stop and polls slowly")
    func ended() async throws {
        let bots = ScriptedBots()
        bots.script("bot.teach.status", status(ended: "limit"))
        let snapshot = try await service(bots).status(for: "b")
        #expect(snapshot.phase(live: true) == .ended)
        #expect(snapshot.pollDelay == TeachSnapshot.endedPoll)
    }

    @Test("start names the viewer that holds the lease")
    func start() async throws {
        let bots = ScriptedBots()
        bots.script("bot.teach.start", status(recording: true, capture: "waiting", deadlineAt: 1600))
        let snapshot = try await service(bots).start(for: "b", viewerID: "viewer-1")
        #expect(bots.calls(to: "bot.teach.start").first?.params["viewer_id"] == "viewer-1")
        #expect(snapshot.isRecording)
    }

    @Test("gateway refusals map to what the owner can act on")
    func refusals() async {
        let table: [(String, TeachFailure)] = [
            ("not_in_control", .notInControl), ("draft_pending", .draftPending),
            ("recording_in_progress", .recordingInProgress), ("draft_changed", .draftChanged),
            ("recording_deleted", .recordingDeleted), ("invalid_skill", .invalidSkill),
            ("extra_files", .extraFiles), ("internal", .failed),
        ]
        for (code, expected) in table {
            let bots = ScriptedBots()
            bots.script("bot.teach.start") { _ in throw refusal(code) }
            await #expect(throws: expected) { try await service(bots).start(for: "b", viewerID: "v") }
        }
    }

    @Test("a gateway without the teach methods reads as unavailable, a dropped link as offline")
    func transportFailures() async {
        let missing = ScriptedBots()
        missing.script("bot.teach.status") { _ in throw GatewayTransportError.rpc(RPCError(code: -32601, message: "method not found")) }
        await #expect(throws: TeachFailure.unavailable) { try await service(missing).status(for: "b") }
        let down = ScriptedBots()
        down.script("bot.teach.status") { _ in throw GatewayTransportError.timedOut }
        await #expect(throws: TeachFailure.offline) { try await service(down).status(for: "b") }
    }

    @Test("stop returns the hidden-turn prompt, and an empty recording returns none")
    func stop() async throws {
        let bots = ScriptedBots()
        bots.script("bot.teach.stop", ["empty": false, "teach_id": "t1", "prompt": "write the skill"])
        bots.script("bot.teach.stop", ["empty": true, "reason": "nothing_recorded"])
        let sent = try await service(bots).stop(for: "b", discard: false)
        #expect(sent.prompt == "write the skill")
        #expect(bots.calls(to: "bot.teach.stop").first?.params["discard"] == .bool(false))
        let empty = try await service(bots).stop(for: "b", discard: true)
        #expect(empty.isEmpty)
    }

    @Test("a draft that is ready, single-file and hashed can be approved")
    func draftDecoding() async throws {
        let bots = ScriptedBots()
        bots.script("bot.teach.draft", draft())
        let loaded = try await service(bots).draft(for: "b", teachID: "t1")
        #expect(loaded.content == "# Skill")
        #expect(loaded.canApprove)
    }

    @Test("a draft still being written has no content and cannot be approved")
    func draftNotReady() async throws {
        let bots = ScriptedBots()
        bots.script("bot.teach.draft", draft(state: "drafting", content: .null, hash: .null))
        let loaded = try await service(bots).draft(for: "b", teachID: "t1")
        #expect(!loaded.isReady)
        #expect(!loaded.canApprove)
    }

    @Test("approve sends the hash of what was read and nothing else about the content")
    func approve() async throws {
        let bots = ScriptedBots()
        bots.script("bot.teach.draft", draft())
        bots.script("bot.teach.approve", ["teach_id": "t1", "skill_name": "file-expenses", "enabled": true])
        let loaded = try await service(bots).draft(for: "cho-ua", teachID: "t1")
        let name = try await service(bots).approve(for: "cho-ua", draft: loaded)
        let call = try #require(bots.calls(to: "bot.teach.approve").first)
        #expect(name == "file-expenses")
        #expect(call.params["content_hash"] == "h1")
        #expect(!call.params.keys.contains("content"))
        #expect(call.params["profile"] == "cho-ua")
    }

    @Test("a draft with extra files is never sent for approval")
    func extraFilesBlockApprove() async throws {
        let bots = ScriptedBots()
        bots.script("bot.teach.draft", draft(extraFiles: ["run.sh"]))
        let loaded = try await service(bots).draft(for: "b", teachID: "t1")
        #expect(!loaded.canApprove)
        await #expect(throws: TeachFailure.notReady) { try await service(bots).approve(for: "b", draft: loaded) }
        #expect(bots.calls(to: "bot.teach.approve").isEmpty)
    }

    @Test("an approval that races a changed draft reports draft changed")
    func approveRace() async throws {
        let bots = ScriptedBots()
        bots.script("bot.teach.draft", draft())
        bots.script("bot.teach.approve") { _ in throw refusal("draft_changed") }
        let loaded = try await service(bots).draft(for: "b", teachID: "t1")
        await #expect(throws: TeachFailure.draftChanged) { try await service(bots).approve(for: "b", draft: loaded) }
    }

    @Test("discard names the draft and fails loudly when the gateway did not discard")
    func discard() async throws {
        let bots = ScriptedBots()
        bots.script("bot.teach.discard", ["teach_id": "t1", "discarded": true])
        try await service(bots).discard(for: "b", teachID: "t1")
        #expect(bots.calls(to: "bot.teach.discard").first?.params["teach_id"] == "t1")
        let refused = ScriptedBots()
        refused.script("bot.teach.discard", ["teach_id": "t1", "discarded": false])
        await #expect(throws: TeachFailure.failed) { try await service(refused).discard(for: "b", teachID: "t1") }
    }
}
