import Foundation
import PalProtocol
import PalRoster
import PalTransport
import Synchronization
import Testing

private let bots = [
    SearchBot(name: "default", displayName: "chó pal bot", sessionIDs: ["s-default"]),
    SearchBot(name: "cho-ua", displayName: "chó UA", sessionIDs: ["s-ua", "s-ua-tip"]),
    SearchBot(name: "upwork-hunter", displayName: "Upwork Hunter", sessionIDs: ["s-upwork"]),
]

private final class Recorder: Sendable {
    private let log = Mutex<[(method: String, params: JSONValue?)]>([])
    func add(_ method: String, _ params: JSONValue?) { log.withLock { $0.append((method, params)) } }
    func calls(_ method: String) -> [JSONValue?] { log.withLock { $0.filter { $0.method == method }.map(\.params) } }
}

private func engine(
    recorder: Recorder = Recorder(),
    limits: SearchEngine.Limits = .init(),
    handler: @escaping @Sendable (String, JSONValue?) -> FakeGateway.Reply
) async throws -> (SearchEngine, FakeGateway, GatewayConnection, Recorder) {
    let gateway = try await FakeGateway.start { method, params, _ in
        recorder.add(method, params)
        return handler(method, params)
    }
    let (rpc, connection) = try await rosterGateway(gateway)
    return (SearchEngine(gateway: rpc, limits: limits), gateway, connection, recorder)
}

private func hit(_ session: String, _ snippet: String, profile: String, at: Int? = nil, resolved: String? = nil) -> JSONValue {
    var row: [String: JSONValue] = ["session_id": .string(session), "snippet": .string(snippet), "profile": .string(profile), "role": "assistant"]
    if let at { row["timestamp"] = .int(at) }
    if let resolved { row["resolved_id"] = .string(resolved) }
    return .object(row)
}

@Suite("Search sources")
struct SearchEngineTests {
    @Test func botsFilterByNameAndEmptyQueryListsEveryBot() async throws {
        let (engine, gateway, connection, recorder) = try await engine { _, _ in .result([:]) }
        defer { gateway.stop(); Task { await connection.close() } }

        let all = try await engine.run(.bots, query: "  ", bots: bots)
        #expect(all.items.count == 3)
        let ua = try await engine.run(.bots, query: "cho", bots: bots)
        #expect(ua.items.compactMap { if case .bot(let hit) = $0 { hit.botName } else { nil } } == ["default", "cho-ua"])
        let accentInsensitive = try await engine.run(.bots, query: "upwork", bots: bots)
        #expect(accentInsensitive.items.count == 1)
        #expect(recorder.calls("profiles.list").isEmpty)
    }

    @Test func messagesMergeAcrossBotsNewestFirstAndMapToTheirBotChat() async throws {
        let (engine, gateway, connection, recorder) = try await engine { method, params in
            guard method == "session.search" else { return .failure(RPCError(code: -1, message: "x")) }
            switch params?["profile"]?.stringValue {
            case "default": return .result(["results": [hit("s-default", "zanzibar one", profile: "default", at: 100)]])
            case "cho-ua": return .result(["results": [
                hit("s-ua", "zanzibar two", profile: "cho-ua", at: 300),
                hit("old-root", "zanzibar tip", profile: "cho-ua", at: 200, resolved: "s-ua-tip"),
            ]])
            default: return .result(["results": []])
            }
        }
        defer { gateway.stop(); Task { await connection.close() } }

        let state = try await engine.run(.messages, query: " zanzibar ", bots: bots)

        let hits = state.items.compactMap { if case .message(let hit) = $0 { hit } else { nil } }
        #expect(hits.map(\.snippet) == ["zanzibar two", "zanzibar tip", "zanzibar one"])
        #expect(hits.map(\.botName) == ["cho-ua", "cho-ua", "default"])
        #expect(hits[1].sessionID == "s-ua-tip")
        #expect(state.items.map(\.destination) == [.chat(botName: "cho-ua"), .chat(botName: "cho-ua"), .chat(botName: "default")])
        #expect(!state.isIncomplete)
        let call = try #require(recorder.calls("session.search").first ?? nil)
        #expect(call["query"] == "zanzibar" && call["limit"] == 10)
    }

    @Test func hitsInASessionThatBelongsToNoBotChatAreDropped() async throws {
        let (engine, gateway, connection, _) = try await engine { _, _ in
            .result(["results": [
                hit("some-scratch-session", "zanzibar elsewhere", profile: "cho-ua", at: 5),
                hit("s-ua", "zanzibar mine", profile: "cho-ua", at: 4),
            ]])
        }
        defer { gateway.stop(); Task { await connection.close() } }

        let state = try await engine.run(.messages, query: "zanzibar", bots: [bots[1]])

        #expect(state.items.count == 1)
    }

    @Test func emptyMessageQueryNeverCallsTheGateway() async throws {
        let (engine, gateway, connection, recorder) = try await engine { _, _ in .result([:]) }
        defer { gateway.stop(); Task { await connection.close() } }

        let state = try await engine.run(.messages, query: "   ", bots: bots)

        #expect(state.items.isEmpty && state.phase == .loaded)
        #expect(recorder.calls("session.search").isEmpty)
    }

    @Test func oneBotFailingMarksTheSourceIncompleteButKeepsTheRest() async throws {
        let (engine, gateway, connection, _) = try await engine { _, params in
            switch params?["profile"]?.stringValue {
            case "cho-ua": .failure(RPCError(code: 5000, message: "boom"))
            case "default": .result(["results": [hit("s-default", "zanzibar", profile: "default", at: 1)]])
            default: .result(["results": []])
            }
        }
        defer { gateway.stop(); Task { await connection.close() } }

        let state = try await engine.run(.messages, query: "zanzibar", bots: bots)

        #expect(state.items.count == 1 && state.isIncomplete && state.phase == .loaded)
    }

    @Test func everyBotFailingFailsTheSource() async throws {
        let (engine, gateway, connection, _) = try await engine { _, _ in
            .failure(RPCError(code: -32601, message: "unknown_method"))
        }
        defer { gateway.stop(); Task { await connection.close() } }

        await #expect(throws: (any Error).self) { try await engine.run(.messages, query: "zanzibar", bots: bots) }
    }

    @Test func perBotCallsAreCappedInParallelAndStillAllMade() async throws {
        let wide = (0..<9).map { SearchBot(name: "bot-\($0)", displayName: "Bot \($0)", sessionIDs: ["s-\($0)"]) }
        let (engine, gateway, connection, recorder) = try await engine(limits: .init(concurrency: 3)) { _, _ in
            .delayed(.milliseconds(80), ["results": []])
        }
        defer { gateway.stop(); Task { await connection.close() } }

        let started = ContinuousClock.now
        _ = try await engine.run(.messages, query: "q", bots: wide)
        let elapsed = ContinuousClock.now - started

        #expect(recorder.calls("session.search").count == 9)
        #expect(elapsed >= .milliseconds(220), "nine 80 ms calls under a cap of three take at least three waves")
        #expect(elapsed < .seconds(5))
    }

    @Test func filesAreListedAcrossBotsFilteredLocallyAndSortedNewestFirst() async throws {
        let (engine, gateway, connection, recorder) = try await engine { method, params in
            guard method == "library.list" else { return .failure(RPCError(code: -1, message: "x")) }
            let profile = params?["profile"]?.stringValue ?? ""
            return .result(["items": [
                ["id": .string("\(profile)-1"), "kind": "file", "title": "report.pdf", "subtitle": .string("from \(profile)"),
                 "session_id": "s", "occurred_at": profile == "cho-ua" ? "2026-03-02T10:00:00.123456+00:00" : "2026-03-01T10:00:00+00:00",
                 "mime": "application/pdf", "size": 12, "asset_ref": "ref"],
                ["id": .string("\(profile)-2"), "kind": "link", "title": "Notion", "subtitle": "notion.so", "url": "https://notion.so",
                 "session_id": "s", "occurred_at": "2026-01-01T00:00:00+00:00"],
            ]])
        }
        defer { gateway.stop(); Task { await connection.close() } }

        let everything = try await engine.run(.files, query: "", bots: bots)
        #expect(everything.items.count == 6)
        let pdfs = try await engine.run(.files, query: "report", bots: bots)
        let files = pdfs.items.compactMap { if case .file(let hit) = $0 { hit } else { nil } }
        #expect(files.map(\.botName) == ["cho-ua", "default", "upwork-hunter"])
        #expect(files[0].kind == .file && files[0].assetRef == "ref" && files[0].size == 12)
        #expect(files[0].occurredAt != nil && files[1].occurredAt != nil)
        #expect(recorder.calls("library.list").count == 6)
    }

    @Test func routinesListPerBotAndFilterByNamePromptOrSchedule() async throws {
        let (engine, gateway, connection, recorder) = try await engine { method, params in
            guard method == "cron.manage" else { return .failure(RPCError(code: -1, message: "x")) }
            if params?["profile"]?.stringValue == "upwork-hunter" { return .result(["error": "cron store unavailable"]) }
            return .result(["jobs": [
                ["job_id": "j1", "name": "Morning digest", "schedule": "0 8 * * *", "schedule_text": "every day at 8:00",
                 "prompt_preview": "send the AI news", "enabled": true, "next_run_at": "2026-03-02T08:00:00+00:00"],
                ["job_id": "j2", "name": "", "schedule": "30m", "prompt_preview": "ping", "enabled": false],
            ]])
        }
        defer { gateway.stop(); Task { await connection.close() } }

        let digest = try await engine.run(.routines, query: "digest", bots: bots)

        let routines = digest.items.compactMap { if case .routine(let hit) = $0 { hit } else { nil } }
        #expect(routines.map(\.jobID) == ["j1", "j1"])
        #expect(digest.isIncomplete)
        #expect(routines[0].schedule == "every day at 8:00" && routines[0].nextRunAt != nil)
        let call = try #require(recorder.calls("cron.manage").first ?? nil)
        #expect(call["action"] == "list" && call["include_disabled"] == true)
        let disabled = try await engine.run(.routines, query: "ping", bots: bots)
        let unnamed = disabled.items.compactMap { if case .routine(let hit) = $0 { hit } else { nil } }
        #expect(unnamed.first?.name == "ping" && unnamed.first?.isEnabled == false)
    }

    @Test func routinesErrorFromEveryBotFailsTheSource() async throws {
        let (engine, gateway, connection, _) = try await engine { _, _ in .result(["error": "nope"]) }
        defer { gateway.stop(); Task { await connection.close() } }

        await #expect(throws: (any Error).self) { try await engine.run(.routines, query: "", bots: bots) }
    }

    @Test func groupChatsComeFromOneListCallFilteredByNameOrMember() async throws {
        let (engine, gateway, connection, recorder) = try await engine { method, _ in
            guard method == "groups.list" else { return .failure(RPCError(code: -1, message: "x")) }
            return .result(["rooms": [
                ["room_id": "r1", "name": "Launch crew", "updated_at": 200.5,
                 "members": [["profile": "cho-ua", "display_name": "chó UA"], ["profile": "default", "handle": "hermes"]]],
                ["room_id": "r2", "name": "Ideas", "updated_at": 100,
                 "members": [["profile": "upwork-hunter", "display_name": "Upwork Hunter"]]],
            ]])
        }
        defer { gateway.stop(); Task { await connection.close() } }

        let byName = try await engine.run(.groupChats, query: "launch", bots: bots)
        let byMember = try await engine.run(.groupChats, query: "upwork", bots: bots)
        let all = try await engine.run(.groupChats, query: "", bots: bots)

        #expect(byName.items.map(\.destination) == [.groupChat(roomID: "r1")])
        #expect(byMember.items.map(\.destination) == [.groupChat(roomID: "r2")])
        #expect(all.items.map(\.destination) == [.groupChat(roomID: "r1"), .groupChat(roomID: "r2")])
        #expect(recorder.calls("groups.list").count == 3)
    }

    @Test func scopesExpandIntoTheirSourcesAndAllCoversEveryone() {
        #expect(SearchScope.all.sources == [.bots, .messages, .groupChats, .files, .routines])
        #expect(SearchScope.messages.sources == [.messages])
    }
}

@Suite("Search coordinator")
struct SearchCoordinatorTests {
    private func collect(_ coordinator: SearchCoordinator, until done: @escaping @Sendable (SearchState) -> Bool) async -> [SearchState] {
        var seen: [SearchState] = []
        for await state in coordinator.states {
            seen.append(state)
            if done(state) { break }
        }
        return seen
    }

    @Test func staleQueriesNeverPublishAndAreNeverSentOnceSuperseded() async throws {
        let (engine, gateway, connection, recorder) = try await engine { _, params in
            .result(["results": [hit("s-ua", params?["query"]?.stringValue ?? "", profile: "cho-ua", at: 1)]])
        }
        defer { gateway.stop(); Task { await connection.close() } }
        let coordinator = SearchCoordinator(engine: engine, debounce: .milliseconds(150))
        let only = [bots[1]]

        await coordinator.update(query: "za", sources: [.messages], bots: only)
        try await Task.sleep(for: .milliseconds(40))
        await coordinator.update(query: "zanzibar", sources: [.messages], bots: only)

        let seen = await collect(coordinator) { $0.state(of: .messages).phase == .loaded && $0.query == "zanzibar" }
        await coordinator.stop()

        #expect(recorder.calls("session.search").count == 1)
        #expect(!seen.contains { $0.query == "za" && $0.state(of: .messages).phase == .loaded })
        let final = try #require(seen.last)
        #expect(final.items(for: .messages).count == 1)
    }

    @Test func aSlowSupersededResponseIsIgnored() async throws {
        let (engine, gateway, connection, _) = try await engine { _, params in
            let query = params?["query"]?.stringValue ?? ""
            let reply: JSONValue = ["results": [hit("s-ua", query, profile: "cho-ua", at: 1)]]
            return query == "slow" ? .delayed(.milliseconds(400), reply) : .result(reply)
        }
        defer { gateway.stop(); Task { await connection.close() } }
        let coordinator = SearchCoordinator(engine: engine, debounce: .milliseconds(10))
        let only = [bots[1]]

        await coordinator.update(query: "slow", sources: [.messages], bots: only)
        try await Task.sleep(for: .milliseconds(100))
        await coordinator.update(query: "fast", sources: [.messages], bots: only)
        let seen = await collect(coordinator) { $0.query == "fast" && $0.state(of: .messages).phase == .loaded }
        try await Task.sleep(for: .milliseconds(500))
        await coordinator.stop()

        let snippets = seen.flatMap { $0.items(for: .messages) }.compactMap { item -> String? in
            if case .message(let hit) = item { hit.snippet } else { nil }
        }
        #expect(!snippets.contains("slow"))
        #expect(snippets.contains("fast"))
    }

    @Test func oneSourceFailingLeavesTheOthersLoaded() async throws {
        let (engine, gateway, connection, _) = try await engine { method, _ in
            switch method {
            case "session.search": .failure(RPCError(code: -32601, message: "unknown_method"))
            case "groups.list": .result(["rooms": [["room_id": "r1", "name": "Crew", "members": []]]])
            default: .failure(RPCError(code: -1, message: "x"))
            }
        }
        defer { gateway.stop(); Task { await connection.close() } }
        let coordinator = SearchCoordinator(engine: engine, debounce: .milliseconds(5))

        await coordinator.update(query: "crew", sources: [.bots, .messages, .groupChats], bots: bots)
        let seen = await collect(coordinator) { state in
            [SearchScope.messages, .groupChats].allSatisfy { state.state(of: $0).phase != .loading }
        }
        await coordinator.stop()

        let final = try #require(seen.last)
        #expect(final.state(of: .messages).phase == .failed)
        #expect(final.state(of: .groupChats).phase == .loaded && final.items(for: .groupChats).count == 1)
        #expect(final.state(of: .bots).phase == .loaded)
        #expect(final.failedSources(in: .all) == [.messages])
        #expect(final.isLoading(.all) == false)
    }

    @Test func botsAnswerImmediatelyAndEmptyQueryNeedsNoDebounceOrMessages() async throws {
        let (engine, gateway, connection, recorder) = try await engine { _, _ in .result([:]) }
        defer { gateway.stop(); Task { await connection.close() } }
        let coordinator = SearchCoordinator(engine: engine, debounce: .seconds(30))

        await coordinator.update(query: "", sources: [.bots, .messages], bots: bots)
        let seen = await collect(coordinator) { _ in true }
        await coordinator.stop()

        let first = try #require(seen.first)
        #expect(first.state(of: .bots).items.count == 3)
        #expect(first.state(of: .messages).phase == .loaded && first.items(for: .messages).isEmpty)
        #expect(recorder.calls("session.search").isEmpty)
    }
}
