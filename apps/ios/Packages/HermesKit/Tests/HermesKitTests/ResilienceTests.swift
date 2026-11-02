import Foundation
import HermesAuth
import HermesChat
import HermesClient
import HermesDiagnostics
import HermesProtocol
import HermesREST
import HermesTransport
import Synchronization
import Testing

private func rpcFailure(_ code: Int, _ message: String, reason: String? = nil, detail: String? = nil) -> GatewayTransportError {
    var data: [String: JSONValue] = [:]
    if let reason { data["reason"] = .string(reason) }
    if let detail { data["detail"] = .string(detail) }
    return .rpc(RPCError(code: code, message: message, data: data.isEmpty ? nil : .object(data)))
}

private struct ThrowingSubmitter: OutboxSubmitter {
    let error: @Sendable () -> any Error

    func submit(_ entry: OutboxEntry) async throws -> AdmissionStatus {
        throw error()
    }
}

private struct AcceptingSubmitter: OutboxSubmitter {
    func submit(_ entry: OutboxEntry) async throws -> AdmissionStatus {
        try JSONValue.object(["admission_id": "a", "status": "queued"]).decoded(as: AdmissionStatus.self)
    }
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("hermes-resilience-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("Outbox error classification")
struct OutboxClassificationTests {
    @Test(arguments: ["permission_denied", "invalid_params", "admission_conflict", "profile_mismatch"])
    func permanentRefusalsFailTheEntry(reason: String) async throws {
        let outbox = try Outbox(
            directory: try temporaryDirectory(),
            submitter: ThrowingSubmitter { rpcFailure(4001, reason, reason: reason) }
        )
        let entry = try await outbox.enqueue(botID: "b", text: "t")
        #expect(await outbox.deliver(entry.submissionID) == .failed(reason: reason))
        #expect(await outbox.pending().isEmpty)
    }

    @Test(arguments: [
        rpcFailure(-32603, "database is locked"),
        rpcFailure(5001, "storage_unavailable", reason: "storage_unavailable"),
        rpcFailure(5006, "sqlite busy", reason: "sqlite_busy"),
        rpcFailure(4001, "invalid_params", detail: "x"),
        rpcFailure(-32603, "internal error", reason: "stale_generation"),
        GatewayTransportError.timedOut,
        GatewayTransportError.closed(.lost),
    ])
    func everythingElseIsRetried(error: GatewayTransportError) async throws {
        let outbox = try Outbox(directory: try temporaryDirectory(), submitter: ThrowingSubmitter { error })
        let entry = try await outbox.enqueue(botID: "b", text: "t")
        #expect(await outbox.deliver(entry.submissionID) == .retryLater)
        let kept = try #require(await outbox.pending().first)
        #expect(kept.submissionID == entry.submissionID)
        #expect(kept.attempts == 1)
    }

    @Test func retriesBackOffExponentiallyForPendingDelivery() async throws {
        let clock = Mutex(Date(timeIntervalSince1970: 1_000_000))
        let outbox = try Outbox(
            directory: try temporaryDirectory(),
            submitter: ThrowingSubmitter { rpcFailure(-32603, "database is locked") },
            now: { clock.withLock { $0 } }
        )
        let entry = try await outbox.enqueue(botID: "b", text: "t")
        #expect(await outbox.deliverPending() == [.retryLater])
        #expect(await outbox.deliverPending().isEmpty, "not due yet")
        clock.withLock { $0 = $0.addingTimeInterval(1) }
        #expect(await outbox.deliverPending().isEmpty, "still inside the first backoff")
        clock.withLock { $0 = $0.addingTimeInterval(60) }
        #expect(await outbox.deliverPending() == [.retryLater])
        let waiting = try #require(await outbox.pending().first)
        #expect(waiting.attempts == 2)
        #expect(try #require(waiting.nextAttemptAt) > clock.withLock { $0 }.addingTimeInterval(3))
        #expect(await outbox.deliver(entry.submissionID) == .retryLater, "explicit delivery ignores the backoff")
    }
}

@Suite("Outbox storage")
struct OutboxStorageTests {
    @Test func twoInstancesWritingConcurrentlyLoseNothing() async throws {
        let directory = try temporaryDirectory()
        let first = try Outbox(directory: directory, submitter: AcceptingSubmitter())
        let second = try Outbox(directory: directory, submitter: AcceptingSubmitter())
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<30 {
                group.addTask { _ = try await first.enqueue(botID: "a", text: "first-\(index)") }
                group.addTask { _ = try await second.enqueue(botID: "b", text: "second-\(index)") }
            }
            try await group.waitForAll()
        }
        #expect(try OutboxStore(directory: directory).load().count == 60)
        #expect(await first.snapshot().count == 60)
        #expect(await second.snapshot().count == 60)
    }

    @Test func aWriteByAnotherProcessIsNotOverwrittenByAnAdmission() async throws {
        let directory = try temporaryDirectory()
        let app = try Outbox(directory: directory, submitter: AcceptingSubmitter())
        let queued = try await app.enqueue(botID: "a", text: "from app")
        let shareExtension = try Outbox(directory: directory, submitter: AcceptingSubmitter())
        let shared = try await shareExtension.enqueue(botID: "a", text: "from extension")
        _ = await app.deliver(queued.submissionID)
        let stored = try OutboxStore(directory: directory).load()
        #expect(Set(stored.map(\.submissionID)) == [queued.submissionID, shared.submissionID])
        #expect(stored.first { $0.submissionID == queued.submissionID }?.state == .admitted(admissionID: "a"))
        #expect(stored.first { $0.submissionID == shared.submissionID }?.state == .pending)
    }

    @Test func aCorruptFileIsQuarantinedUnderAUniqueNameAndLoggedWithoutContent() throws {
        let directory = try temporaryDirectory()
        let recorder = DiagnosticRecorder()
        let store = OutboxStore(directory: directory, diagnostics: recorder.diagnostics)
        for round in 0..<2 {
            try Data("{\"entries\": [{\"text\": \"private-note-\(round)\"}, {}], broken".utf8).write(to: store.fileURL)
            #expect(try store.load().isEmpty)
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let quarantined = names.filter { $0.hasPrefix("outbox.corrupt-") }
        #expect(quarantined.count == 2, "two quarantines in the same second must not collide")
        for name in quarantined {
            let suffix = name.dropFirst("outbox.corrupt-".count).dropLast(".json".count)
            #expect(UUID(uuidString: String(suffix)) != nil)
        }
        #expect(!recorder.transcript.contains("private-note"))
        #expect(!recorder.transcript.contains(directory.path))
        #expect(recorder.events.contains { $0.message.contains("quarantined") && $0.message.contains("entries=") })
    }
}

@Suite("Transcript resilience")
struct TranscriptResilienceTests {
    private func snapshot(running: Bool = false, sequence: Int = 1, messages: [(String, String)] = []) throws -> SessionSnapshot {
        let rows: [JSONValue] = messages.enumerated().map { ["role": .string($1.0), "text": .string($1.1), "row_id": .int($0 + 1)] }
        let object: JSONValue = [
            "session_id": "s1", "messages": .array(rows), "running": .bool(running), "replay_epoch": "e1",
            "last_sequence": .int(sequence), "execution_generation": 1, "pending": [], "prompts": [],
        ]
        return try object.decoded(as: SessionSnapshot.self)
    }

    private func frame(_ type: String, _ payload: JSONValue, seq: Int, epoch: String = "e1") -> SessionEventFrame {
        SessionEventFrame(event: SessionEvent(type: type, payload: payload), sessionID: "s1", seq: seq, replayEpoch: epoch)
    }

    private func gap() -> SessionEventFrame {
        SessionEventFrame(event: SessionEvent(type: "session.replay_gap", payload: ["latest_seq": 9]), sessionID: "s1")
    }

    @Test func framesAreRefusedWhileAResyncIsPending() throws {
        var transcript = Transcript()
        _ = transcript.reconcile(with: try snapshot())
        #expect(transcript.apply(gap()) == .resyncRequired(.replayGap))
        let before = transcript
        #expect(transcript.apply(frame("message.delta", ["text": "ghost", "segment": 0, "offset": 0], seq: 5)) == .ignored)
        #expect(transcript == before)
        _ = transcript.reconcile(with: try snapshot(sequence: 9))
        #expect(transcript.apply(frame("message.delta", ["text": "ok", "segment": 0, "offset": 0], seq: 10)) == .applied)
    }

    @Test func aGapDropsTheStaleStreamingTail() throws {
        var transcript = Transcript()
        _ = transcript.reconcile(with: try snapshot())
        _ = transcript.apply(frame("message.delta", ["text": "half a sent", "segment": 0, "offset": 0], seq: 2))
        #expect(transcript.assistantTexts == ["half a sent"])
        _ = transcript.apply(gap())
        #expect(transcript.assistantTexts.isEmpty)
    }

    @Test func aSnapshotDuringStreamingDropsTheTailAndCompleteRestoresTheText() throws {
        var transcript = Transcript()
        _ = transcript.reconcile(with: try snapshot(running: true))
        _ = transcript.apply(frame("message.delta", ["text": "half a sent", "segment": 0, "offset": 0], seq: 2))
        transcript.requestResync()
        _ = transcript.reconcile(with: try snapshot(running: true, sequence: 8, messages: [("user", "q")]))
        #expect(transcript.assistantTexts.isEmpty, "stale tail is not carried across the snapshot")
        _ = transcript.apply(frame("message.complete", ["text": "half a sentence, done"], seq: 9))
        #expect(transcript.assistantTexts == ["half a sentence, done"])
    }

    @Test func aFailedEchoCarriesItsReasonAndDoesNotBlockLaterConfirmations() throws {
        var transcript = Transcript()
        _ = transcript.reconcile(with: try snapshot())
        transcript.echoUser(submissionID: "bad", text: "refused")
        transcript.echoUser(submissionID: "good", text: "fine")
        transcript.markFailed(submissionID: "bad", reason: "permission_denied")
        let failed = try #require(transcript.items.first { $0.id == "submission:bad" })
        #expect(failed.deliveryFailure == "permission_denied")
        _ = transcript.apply(frame("message.start", [:], seq: 2))
        let good = try #require(transcript.items.first { $0.id == "submission:good" })
        guard case .user(_, let delivery) = good.content else { Issue.record("not a user item"); return }
        #expect(delivery == .sent)
        #expect(good.deliveryFailure == nil)
    }
}

@Suite("Auth refresh races")
struct AuthRefreshRaceTests {
    private final class GatedTransport: HTTPTransport {
        private let release = Mutex<CheckedContinuation<Void, Never>?>(nil)
        private let arrived = Mutex<CheckedContinuation<Void, Never>?>(nil)
        private let arrivedFlag = Mutex(false)
        let status: Int

        init(status: Int) { self.status = status }

        func send(_ request: URLRequest) async throws -> HTTPResult {
            arrivedFlag.withLock { $0 = true }
            arrived.withLock { $0 }?.resume()
            await withCheckedContinuation { continuation in release.withLock { $0 = continuation } }
            let body = status == 200
                ? #"{"access_token":"old-access-2","refresh_token":"old-refresh-2","expires_at":4000000000}"#
                : #"{"detail":"expired"}"#
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return HTTPResult(data: Data(body.utf8), response: response)
        }

        func waitForRequest() async {
            while !arrivedFlag.withLock({ $0 }) { try? await Task.sleep(for: .milliseconds(10)) }
            while release.withLock({ $0 }) == nil { try? await Task.sleep(for: .milliseconds(10)) }
        }

        func releaseRequest() { release.withLock { $0 }?.resume() }
    }

    private func credentials(_ tag: String, host: String = "https://hermes.example.com", expired: Bool) throws -> StoredCredentials {
        StoredCredentials(
            baseURL: try GatewayBaseURL(validating: host),
            tokens: TokenSet(
                accessToken: "access-\(tag)",
                refreshToken: "refresh-\(tag)",
                expiresAt: Date(timeIntervalSince1970: expired ? 1 : 4_000_000_000),
                provider: "basic",
                userID: "user-\(tag)"
            )
        )
    }

    @Test(arguments: [200, 401])
    func signOutAndAdoptDuringARefreshKeepTheNewCredentials(status: Int) async throws {
        let transport = GatedTransport(status: status)
        let store = InMemoryCredentialStore()
        let session = try AuthSession(store: store, transport: transport)
        try await session.adopt(try credentials("old", expired: true))
        let refreshing = Task { try? await session.accessToken() }
        await transport.waitForRequest()
        try await session.signOut()
        let replacement = try credentials("new", host: "https://other.example.com", expired: false)
        try await session.adopt(replacement)
        transport.releaseRequest()
        _ = await refreshing.value
        #expect(try store.load() == replacement)
        #expect(await session.userID == "user-new")
        #expect(await session.isSignedIn)
        #expect(await session.baseURL == replacement.baseURL)
    }
}

@Suite("Chat session against a scripted gateway", .serialized)
struct ScriptedChatTests {
    private func session(
        _ connector: ScriptedConnector,
        diagnostics: Diagnostics = .silent
    ) -> ChatSession {
        ChatSession(
            profile: "bot",
            connector: connector,
            reconnectPolicy: ReconnectPolicy(initialDelay: .milliseconds(20), maximumDelay: .milliseconds(80)),
            diagnostics: diagnostics
        )
    }

    @Test func dialNegotiatesTheSubprotocolEveryTime() async throws {
        let script = BotScript()
        let gateway = try await FakeGateway.start(script.handle)
        defer { gateway.stop() }
        for attempt in 0..<50 {
            let connection = try await GatewayConnection.dial(url: gateway.url, ticket: "t\(attempt)")
            await connection.close()
        }
        #expect(gateway.connectionCount == 50)
    }

    @Test(arguments: [Duration.zero, Duration.milliseconds(150)])
    func closeRacingStartLeavesNoLiveSocket(connectDelay: Duration) async throws {
        let script = BotScript()
        script.override("session.list") { _ in .delayed(.milliseconds(150), ["sessions": []]) }
        let gateway = try await FakeGateway.start(script.handle)
        defer { gateway.stop() }
        let connector = ScriptedConnector(url: gateway.url, delay: connectDelay)
        let chat = session(connector)
        let starting = Task { try? await chat.start(intro: .kickoff) }
        try await Task.sleep(for: .milliseconds(connectDelay == .zero ? 60 : 60))
        await chat.close()
        _ = await starting.value
        try await waitUntil("every socket to close", timeout: .seconds(5)) { gateway.liveConnectionCount == 0 }
        #expect(await chat.phase == .detached)
        for connection in connector.dialed {
            await #expect(throws: GatewayTransportError.self) { try await connection.ping() }
        }
        #expect(script.count("session.create") == 0)
    }

    @Test func aFailedResyncReconnectsAndAppliesNothingAcrossTheGap() async throws {
        let script = BotScript()
        script.messages.withLock { $0 = [("user", "hello"), ("assistant", "hi there")] }
        script.override("session.resume") { number in
            number == 2 ? .failure(RPCError(code: -32603, message: "database is locked")) : nil
        }
        let gateway = try await FakeGateway.start(script.handle)
        defer { gateway.stop() }
        let connector = ScriptedConnector(url: gateway.url)
        let chat = session(connector)
        try await chat.start()
        script.lastSequence.withLock { $0 = 12 }
        gateway.push(["type": "session.replay_gap", "session_id": "s1", "payload": ["latest_seq": 12]], to: 0)
        gateway.push(script.event("message.delta", seq: 13, payload: ["text": "ghost", "segment": 0, "offset": 0]), to: 0)
        try await waitUntil("a second connection and a live phase", timeout: .seconds(10)) {
            guard case .live(let sequence, _) = await chat.phase else { return false }
            return connector.dialed.count >= 2 && sequence == 12
        }
        let texts = await chat.transcript.assistantTexts
        #expect(!texts.contains { $0.contains("ghost") })
        #expect(texts == ["hi there"])
    }

    @Test(arguments: [
        (SignInError.sessionExpired as any Error, ChatTerminalFailure.sessionExpired),
        (SignInError.notSignedIn as any Error, ChatTerminalFailure.notSignedIn),
        (HermesClientError.notSignedIn as any Error, ChatTerminalFailure.notSignedIn),
        (RESTError.unauthorized as any Error, ChatTerminalFailure.sessionExpired),
        (GatewayTransportError.closed(.forbidden) as any Error, ChatTerminalFailure.accessForbidden),
        (GatewayTransportError.handshakeRejected(status: 401) as any Error, ChatTerminalFailure.sessionExpired),
        (GatewayTransportError.handshakeRejected(status: 403) as any Error, ChatTerminalFailure.accessForbidden),
    ])
    func nonRecoverableErrorsStopReconnecting(error: any Error, expected: ChatTerminalFailure) async throws {
        let script = BotScript()
        let gateway = try await FakeGateway.start(script.handle)
        defer { gateway.stop() }
        let connector = ScriptedConnector(url: gateway.url) { index in index == 0 ? nil : error }
        let chat = session(connector)
        try await chat.start()
        let announced = Task { () -> ChatTerminalFailure? in
            for await failure in chat.terminalFailures { return failure }
            return nil
        }
        gateway.dropAll()
        try await waitUntil("the terminal failure", timeout: .seconds(10)) { await chat.terminalFailure != nil }
        try await Task.sleep(for: .milliseconds(400))
        #expect(await chat.terminalFailure == expected)
        #expect(await announced.value == expected)
        #expect(connector.attempts == 2, "one initial dial and exactly one reconnect attempt")
        #expect(await chat.phase == .detached)
        await chat.close()
    }

    @Test func transientErrorsKeepReconnecting() async throws {
        let script = BotScript()
        let gateway = try await FakeGateway.start(script.handle)
        defer { gateway.stop() }
        let connector = ScriptedConnector(url: gateway.url) { index in
            (1...3).contains(index) ? GatewayTransportError.closed(.lost) : nil
        }
        let chat = session(connector)
        try await chat.start()
        gateway.dropAll()
        try await waitUntil("live again", timeout: .seconds(10)) {
            guard case .live = await chat.phase else { return false }
            return connector.attempts == 5
        }
        #expect(await chat.terminalFailure == nil)
        await chat.close()
    }

    @Test(arguments: ["permission_denied", "profile_mismatch"])
    func aPermanentRefusalMarksTheLocalEchoFailedAndTheEntryToo(reason: String) async throws {
        let script = BotScript()
        script.override("prompt.submit") { _ in .failure(RPCError(code: 4001, message: reason, data: ["reason": .string(reason)])) }
        let gateway = try await FakeGateway.start(script.handle)
        defer { gateway.stop() }
        let chat = session(ScriptedConnector(url: gateway.url))
        try await chat.start()
        let outbox = try Outbox(directory: try temporaryDirectory(), submitter: chat)
        let entry = try await outbox.enqueue(botID: "bot", text: "refuse me")
        #expect(await outbox.deliver(entry.submissionID) == .failed(reason: reason))
        let echo = try #require(await chat.transcript.items.first { item in
            if case .user(let text, _) = item.content { return text == "refuse me" }
            return false
        })
        #expect(echo.deliveryFailure == reason)
        await chat.close()
    }

    @Test func aTransientRefusalLeavesTheEchoPending() async throws {
        let script = BotScript()
        script.override("prompt.submit") { _ in .failure(RPCError(code: -32603, message: "database is locked")) }
        let gateway = try await FakeGateway.start(script.handle)
        defer { gateway.stop() }
        let chat = session(ScriptedConnector(url: gateway.url))
        try await chat.start()
        let outbox = try Outbox(directory: try temporaryDirectory(), submitter: chat)
        let entry = try await outbox.enqueue(botID: "bot", text: "try again")
        #expect(await outbox.deliver(entry.submissionID) == .retryLater)
        #expect(await chat.transcript.items.allSatisfy { $0.deliveryFailure == nil })
        await chat.close()
    }

    @Test func theIntroIsSentWhenTheExistingChatHasNoMessages() async throws {
        let script = BotScript()
        let gateway = try await FakeGateway.start(script.handle)
        defer { gateway.stop() }
        let chat = session(ScriptedConnector(url: gateway.url))
        let outcome = try await chat.start(intro: .kickoff)
        #expect(!outcome.created)
        #expect(outcome.introAdmission != nil)
        let params = try #require(script.submitted.withLock { $0.first })
        #expect(params["submission_id"]?.stringValue == "intro:s1")
        #expect(script.count("session.create") == 0)
        await chat.close()
    }

    @Test func theIntroIsSkippedWhenTheChatAlreadyHasMessages() async throws {
        let script = BotScript()
        script.messages.withLock { $0 = [("user", "hello")] }
        let gateway = try await FakeGateway.start(script.handle)
        defer { gateway.stop() }
        let chat = session(ScriptedConnector(url: gateway.url))
        let outcome = try await chat.start(intro: .kickoff)
        #expect(outcome.introAdmission == nil)
        #expect(script.count("prompt.submit") == 0)
        await chat.close()
    }

    @Test func errorPathsNeverLogMessageTextRpcDataOrUrls() async throws {
        let prompt = "private-note-\(UUID().uuidString.prefix(8))"
        let echoed = RPCError(
            code: -32603,
            message: "failed on \(prompt)",
            data: ["reason": "storage_unavailable", "detail": .string(prompt), "echo": .string(prompt)]
        )
        let script = BotScript()
        script.override("prompt.submit") { _ in .failure(echoed) }
        script.override("session.resume") { number in number == 2 ? .failure(echoed) : nil }
        let gateway = try await FakeGateway.start(script.handle)
        defer { gateway.stop() }
        let recorder = DiagnosticRecorder()
        let secretURL = "https://leak.example.com/\(prompt)?token=\(prompt)"
        let connector = ScriptedConnector(url: gateway.url) { index in
            index == 1 ? URLError(.cannotConnectToHost, userInfo: [NSURLErrorFailingURLStringErrorKey: secretURL, NSLocalizedDescriptionKey: prompt]) : nil
        }
        let chat = session(connector, diagnostics: recorder.diagnostics)
        _ = try await chat.start(intro: BotIntro(text: prompt, hidden: false))
        let outbox = try Outbox(directory: try temporaryDirectory(), submitter: chat, diagnostics: recorder.diagnostics)
        let entry = try await outbox.enqueue(botID: "bot", text: prompt)
        _ = await outbox.deliver(entry.submissionID)
        script.lastSequence.withLock { $0 = 9 }
        gateway.push(["type": "session.replay_gap", "session_id": "s1", "payload": ["latest_seq": 9]], to: 0)
        try await waitUntil("a reconnect after the failed resync", timeout: .seconds(10)) { connector.attempts >= 3 }
        try await waitUntil("a live phase", timeout: .seconds(10)) {
            if case .live = await chat.phase { return true }
            return false
        }
        await chat.close()

        let log = recorder.transcript
        #expect(!log.contains(prompt), "diagnostics leaked server-echoed text")
        #expect(!log.contains("leak.example.com"))
        #expect(!log.contains("token="))
        #expect(log.contains("code=-32603"), "errors still log their code")
        #expect(log.contains("reason=storage_unavailable"))
    }
}
