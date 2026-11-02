import Foundation
import HermesAuth
import HermesChat
import HermesClient
import HermesDiagnostics
import HermesProtocol
import HermesREST
import HermesTransport
import OSLog
import Synchronization
import Testing

private struct E2EContext {
    let environment: E2EEnvironment
    let gateway: LiveGateway
    let transport: RecordingTransport
    let auth: AuthSession
    let recorder: FrameRecorder
    let diagnosticRecorder = DiagnosticRecorder()

    static let subsystem = "dev.tsnanh.hermes.bot.tests.chat"

    var diagnostics: Diagnostics {
        diagnosticRecorder.diagnostics.combined(with: .osLog(subsystem: Self.subsystem))
    }

    static func make() async throws -> E2EContext {
        let environment = try #require(E2EEnvironment.fromEnvironment())
        let gateway = try #require(LiveGateway.fromEnvironment())
        let shared = try await SharedSignIn.shared.session(gateway: gateway)
        return E2EContext(
            environment: environment,
            gateway: gateway,
            transport: shared.transport,
            auth: shared.auth,
            recorder: FrameRecorder(environment: environment)
        )
    }

    func connector(_ label: String) -> TestConnector {
        TestConnector(auth: auth, transport: transport, diagnostics: diagnostics, recorder: recorder, label: label)
    }

    func chat(_ profile: String, _ connector: TestConnector) -> ChatSession {
        ChatSession(
            profile: profile,
            connector: connector,
            reconnectPolicy: ReconnectPolicy(initialDelay: .milliseconds(100), maximumDelay: .seconds(1)),
            diagnostics: diagnostics
        )
    }

    func outboxDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hermes-outbox-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private actor SharedSignIn {
    static let shared = SharedSignIn()

    private var cached: (transport: RecordingTransport, auth: AuthSession)?

    func session(gateway: LiveGateway) async throws -> (transport: RecordingTransport, auth: AuthSession) {
        if let cached { return cached }
        let transport = RecordingTransport()
        let browser = ProgrammaticBrowser(username: gateway.username, password: gateway.password)
        let credentials = try await NativeSignIn(transport: transport).signIn(baseURL: gateway.baseURL, browser: browser)
        let auth = try AuthSession(store: InMemoryCredentialStore(), transport: transport)
        try await auth.adopt(credentials)
        cached = (transport, auth)
        return (transport, auth)
    }
}

private func turnIsSettled(_ transcript: Transcript) -> Bool {
    guard !transcript.isRunning, let last = transcript.items.last else { return false }
    if case .assistant(_, _, let streaming) = last.content { return !streaming }
    return false
}

private func conversation(_ transcript: Transcript) -> [StoredMessage] {
    transcript.summary().conversation.map { StoredMessage(role: $0.kind, content: $0.text) }
}

private func describe(_ messages: [StoredMessage]) -> String {
    messages.map { "\($0.role)[\($0.content.count)]:\($0.content.suffix(24))" }.joined(separator: " | ")
}

private func assertSingleTurn(_ messages: [StoredMessage], userText: String) {
    let indices = messages.indices.filter { messages[$0].role == "user" && messages[$0].content == userText }
    #expect(indices.count == 1, "expected exactly one user turn for the submission")
    guard let index = indices.first else { return }
    #expect(messages.indices.contains(index + 1) && messages[index + 1].role == "assistant", "user turn is answered")
    if messages.indices.contains(index + 2) {
        #expect(messages[index + 2].role == "user", "exactly one assistant turn for the submission")
    }
}

private func inboundCounts(_ log: String) -> [String: Int] {
    var counts: [String: Int] = [:]
    for line in log.split(separator: "\n") where line.contains("inbound message:") {
        guard let start = line.range(of: " msg='"), let end = line.range(of: "' reply_to_id=") else { continue }
        counts[String(line[start.upperBound..<end.lowerBound]), default: 0] += 1
    }
    return counts
}

private struct LossyAckSubmitter: OutboxSubmitter {
    let inner: any OutboxSubmitter
    let lostAcks: Mutable<Int>
    let admitted: Mutable<[AdmissionStatus]>

    func submit(_ entry: OutboxEntry) async throws -> AdmissionStatus {
        let status = try await inner.submit(entry)
        admitted.box.withLock { $0.append(status) }
        let lose = lostAcks.box.withLock { remaining -> Bool in
            guard remaining > 0 else { return false }
            remaining -= 1
            return true
        }
        if lose { throw GatewayTransportError.timedOut }
        return status
    }
}

@Suite("iOS client against an isolated gateway", .serialized, .enabled(if: E2EEnvironment.isConfigured, "run via Scripts/e2e-gateway"))
struct ChatE2ETests {
    @Test func concurrentOpenOfABotWithoutChatMintsExactlyOneBotChat() async throws {
        let context = try await E2EContext.make()
        let environment = context.environment
        let profile = environment.concurrencyProfile
        let first = context.chat(profile, context.connector("a"))
        let second = context.chat(profile, context.connector("b"))
        async let startedFirst = first.start(intro: .kickoff)
        async let startedSecond = second.start(intro: .kickoff)
        let outcomes = try await [startedFirst, startedSecond]
        #expect(outcomes.allSatisfy { $0.created && $0.introAdmission != nil }, "both creators admitted the intro")
        #expect(Set(outcomes.compactMap { $0.introAdmission?.admissionID }).count == 1, "both intros resolved to one admission")

        let database = environment.database(profile)
        let registered = database.sessionIDs(titled: BotChatResolver.title)
        #expect(registered.count == 1, "exactly one session titled Bot Chat")
        #expect(database.sessionCount() == 1, "no orphan session was left by the race")
        let firstID = await first.transcript.sessionID
        let secondID = await second.transcript.sessionID
        #expect(firstID == secondID)
        #expect(firstID == registered.first)

        try await waitUntil("both clients to settle the intro turn") {
            let a = await first.transcript
            let b = await second.transcript
            return turnIsSettled(a) && turnIsSettled(b)
        }
        let stored = database.conversation(sessionID: try #require(registered.first))
        #expect(stored.filter { $0.role == "user" }.count == 1, "one intro turn despite two creators")
        let transcriptA = await first.transcript
        let transcriptB = await second.transcript
        #expect(conversation(transcriptA) == stored, "client a \(describe(conversation(transcriptA))) != stored \(describe(stored))")
        #expect(conversation(transcriptB) == stored, "client b \(describe(conversation(transcriptB))) != stored \(describe(stored))")
        #expect(database.admissionCount(requestID: "intro:\(try #require(registered.first))") == 1)

        try context.recorder.write(
            name: "concurrent-open",
            expected: ["a": transcriptA.summary(), "b": transcriptB.summary()]
        )
        await first.close()
        await second.close()
    }

    @Test func sendAndStreamEndsWithTheAssistantTextInStateDB() async throws {
        let context = try await E2EContext.make()
        let environment = context.environment
        let profile = environment.conversationProfile
        let session = context.chat(profile, context.connector("a"))
        try await session.start()
        let outbox = try Outbox(directory: try context.outboxDirectory(), submitter: session, diagnostics: context.diagnostics)
        let text = nonce("stream")
        let queued = try await outbox.enqueue(botID: profile, text: text)
        guard case .admitted(let status) = await outbox.deliver(queued.submissionID) else {
            Issue.record("expected an admission")
            return
        }
        #expect(!status.admissionID.isEmpty)
        try await waitUntil("the streamed reply to settle") {
            let transcript = await session.transcript
            return turnIsSettled(transcript) && conversation(transcript).contains { $0.content == text }
        }
        let transcript = await session.transcript
        let sessionID = try #require(transcript.sessionID)
        let stored = environment.database(profile).conversation(sessionID: sessionID)
        #expect(conversation(transcript) == stored, "transcript \(describe(conversation(transcript))) != stored \(describe(stored))")
        #expect(transcript.assistantTexts.last == stored.last?.content)
        #expect(environment.database(profile).admissionCount(requestID: queued.submissionID) == 1)
        #expect(inboundCounts(environment.profileLog(profile))[text] == 1)

        try context.recorder.write(name: "send-and-stream", expected: ["a": transcript.summary()])
        await session.close()
    }

    @Test func socketDroppedMidSlowStreamResumesWithoutDuplicatingTheTurn() async throws {
        let context = try await E2EContext.make()
        let environment = context.environment
        let profile = environment.conversationProfile
        let connector = context.connector("a")
        let session = context.chat(profile, connector)
        let phases = Mutex<[ChatPhase]>([])
        let observer = Task {
            for await update in session.updates {
                if case .phase(let phase) = update { phases.withLock { $0.append(phase) } }
            }
        }
        try await session.start()
        let outbox = try Outbox(directory: try context.outboxDirectory(), submitter: session, diagnostics: context.diagnostics)
        let text = "SLOW \(nonce("drop"))"
        let queued = try await outbox.enqueue(botID: profile, text: text)
        guard case .admitted = await outbox.deliver(queued.submissionID) else {
            Issue.record("expected an admission")
            return
        }
        try await waitUntil("the stream to be mid-flight") {
            await session.transcript.items.contains { item in
                if case .assistant(let streamed, _, true) = item.content { return streamed.count > 20 }
                return false
            }
        }
        let beforeDrop = try #require(await session.transcript.cursor)
        await connector.latestConnection?.abort()

        try await waitUntil("the session to reconnect and finish the turn", timeout: .seconds(120)) {
            let transcript = await session.transcript
            guard case .live = await session.phase else { return false }
            return turnIsSettled(transcript) && conversation(transcript).contains { $0.content == text }
        }
        #expect(connector.connections.count >= 2, "the session reconnected with a fresh socket")
        let transcript = await session.transcript
        let afterDrop = try #require(transcript.cursor)
        #expect(afterDrop.lastSequence > beforeDrop.lastSequence)
        #expect(phases.withLock { $0 }.contains(.attaching), "the state machine went through attaching")

        let sessionID = try #require(transcript.sessionID)
        let stored = environment.database(profile).conversation(sessionID: sessionID)
        #expect(conversation(transcript) == stored, "transcript \(describe(conversation(transcript))) != stored \(describe(stored))")
        assertSingleTurn(stored, userText: text)
        #expect(environment.database(profile).admissionCount(requestID: queued.submissionID) == 1)
        #expect(inboundCounts(environment.profileLog(profile))[text] == 1)

        try context.recorder.write(name: "socket-drop-mid-stream", expected: ["a": transcript.summary()])
        observer.cancel()
        await session.close()
    }

    @Test func offlineOutboxDeliversExactlyOnceAcrossLostAcksAndRelaunches() async throws {
        let context = try await E2EContext.make()
        let environment = context.environment
        let profile = environment.conversationProfile
        let connector = context.connector("outbox")
        let directory = try context.outboxDirectory()
        let admitted = Mutable<[AdmissionStatus]>([])
        let lostAcks = Mutable(2)

        func launch() throws -> Outbox {
            let submitter = LossyAckSubmitter(
                inner: BotChatSubmitter(connector: connector, diagnostics: context.diagnostics),
                lostAcks: lostAcks,
                admitted: admitted
            )
            return try Outbox(directory: directory, submitter: submitter, diagnostics: context.diagnostics)
        }

        let reader = context.chat(profile, context.connector("reader"))
        try await reader.start()
        let text = nonce("outbox")
        connector.isOffline = true
        let first = try launch()
        let queued = try await first.enqueue(botID: profile, text: text)
        #expect(await first.deliver(queued.submissionID) == .retryLater)
        #expect(admitted.box.withLock { $0.isEmpty }, "nothing reached the gateway while offline")
        connector.isOffline = false

        let relaunched = try launch()
        let reloaded = try #require(await relaunched.pending(botID: profile).first)
        #expect(reloaded.submissionID == queued.submissionID)
        #expect(reloaded.botID == profile)
        #expect(await relaunched.deliver(queued.submissionID) == .retryLater)

        let relaunchedAgain = try launch()
        #expect(try #require(await relaunchedAgain.pending(botID: profile).first).submissionID == queued.submissionID)
        #expect(await relaunchedAgain.deliver(queued.submissionID) == .retryLater)

        let finalLaunch = try launch()
        guard case .admitted(let status) = await finalLaunch.deliver(queued.submissionID) else {
            Issue.record("expected the third delivery to be acknowledged")
            return
        }
        #expect(await finalLaunch.deliver(queued.submissionID) == .alreadyDone)
        let receipts = admitted.box.withLock { $0 }
        #expect(receipts.count == 3, "the same submission reached the gateway three times")
        #expect(Set(receipts.map(\.admissionID)) == [status.admissionID], "every retry resolved to one admission")

        let database = environment.database(profile)
        try await waitUntil("the turn to be answered in the state DB") {
            let sessionID = database.sessionIDs(titled: BotChatResolver.title).first ?? ""
            let stored = database.conversation(sessionID: sessionID)
            return stored.last?.role == "assistant" && stored.contains { $0.content == text }
        }
        let sessionID = try #require(database.sessionIDs(titled: BotChatResolver.title).first)
        assertSingleTurn(database.conversation(sessionID: sessionID), userText: text)
        #expect(database.admissionCount(requestID: queued.submissionID) == 1)
        #expect(inboundCounts(environment.profileLog(profile))[text] == 1)

        try await waitUntil("the reader to settle the delivered turn") {
            let transcript = await reader.transcript
            return turnIsSettled(transcript) && conversation(transcript).contains { $0.content == text }
        }
        let readerTranscript = await reader.transcript
        #expect(conversation(readerTranscript) == database.conversation(sessionID: sessionID))
        try context.recorder.write(name: "outbox-retries", expected: ["reader": readerTranscript.summary()])
        await reader.close()
    }

    @Test func clarifyCardAppearsAnswerCompletesTheTurn() async throws {
        let context = try await E2EContext.make()
        let environment = context.environment
        let profile = environment.conversationProfile
        let session = context.chat(profile, context.connector("a"))
        try await session.start()
        let outbox = try Outbox(directory: try context.outboxDirectory(), submitter: session, diagnostics: context.diagnostics)
        let text = "CLARIFY \(nonce("ask"))"
        let queued = try await outbox.enqueue(botID: profile, text: text)
        guard case .admitted = await outbox.deliver(queued.submissionID) else {
            Issue.record("expected an admission")
            return
        }
        try await waitUntil("the clarify card") { await !session.transcript.pendingPrompts.isEmpty }
        let prompt = try #require(await session.transcript.pendingPrompts.first)
        #expect(prompt.kind == .clarify)
        #expect(prompt.question == "Which flavor do you want?")
        #expect(prompt.choices.count == 2)
        #expect(prompt.choices.first?.hasPrefix("vanilla") == true)

        try await session.answerClarify(prompt, answer: "chocolate")
        try await waitUntil("the card to settle and the turn to finish") {
            let transcript = await session.transcript
            return transcript.pendingPrompts.isEmpty && turnIsSettled(transcript)
        }
        let transcript = await session.transcript
        #expect(transcript.assistantTexts.last?.contains("chocolate") == true)

        let answeredByStub = environment.stubRequests().contains { request in
            guard let messages = request["messages"]?.arrayValue, let last = messages.last else { return false }
            return last["role"]?.stringValue == "tool" && last["content"]?.stringValue?.contains("chocolate") == true
        }
        #expect(answeredByStub, "the stub saw the answer in the clarify tool result")
        let sessionID = try #require(transcript.sessionID)
        let stored = environment.database(profile).conversation(sessionID: sessionID)
        #expect(conversation(transcript) == stored, "transcript \(describe(conversation(transcript))) != stored \(describe(stored))")
        #expect(environment.database(profile).admissionCount(requestID: queued.submissionID) == 1)

        try context.recorder.write(name: "clarify", expected: ["a": transcript.summary()])
        await session.close()
    }

    @Test func staleReplayCursorDemandsASnapshotAndResumeRestoresTheTranscript() async throws {
        let context = try await E2EContext.make()
        let profile = context.environment.conversationProfile
        let connection = try await context.connector("cursor").connect()
        let api = SessionAPI(connection: connection, profile: profile)
        let resolution = try await BotChatResolver(diagnostics: context.diagnostics).open(api)
        let snapshot = resolution.snapshot

        let wrongEpoch = try await api.eventsSince(sessionID: snapshot.sessionID, lastSequence: 1, replayEpoch: "not-the-epoch")
        #expect(wrongEpoch.snapshotRequired)
        let beyondLatest = try await api.eventsSince(
            sessionID: snapshot.sessionID, lastSequence: snapshot.lastSequence + 10_000, replayEpoch: snapshot.replayEpoch
        )
        #expect(beyondLatest.snapshotRequired)

        var stale = Transcript()
        _ = stale.reconcile(with: snapshot)
        stale.requestResync()
        let resumed = try await api.resume(sessionID: snapshot.sessionID)
        let replaced = stale.reconcile(with: resumed)
        #expect(replaced)
        let stored = context.environment.database(profile).conversation(sessionID: snapshot.sessionID)
        #expect(conversation(stale) == stored)
        await connection.close()
    }

    @Test func gatewayLogsAdmitEachSubmissionOnce() async throws {
        let environment = try #require(E2EEnvironment.fromEnvironment())
        var checked = 0
        for profile in environment.profiles {
            for (text, count) in inboundCounts(environment.profileLog(profile)) {
                #expect(count == 1, "gateway admitted the same message \(count) times")
                checked += text.isEmpty ? 0 : 1
            }
        }
        #expect(checked > 0)
    }

    @Test func profilesListDecodesTheRosterOverTheCanonicalSocket() async throws {
        let context = try await E2EContext.make()
        let connection = try await context.connector("roster").connect()
        let roster = try await SessionAPI(connection: connection, profile: context.environment.conversationProfile).profiles()
        let names = Set(roster.profiles.map(\.name))
        for profile in context.environment.profiles { #expect(names.contains(profile)) }
        await connection.close()
    }

    @Test func diagnosticsNeverContainMessageText() async throws {
        let started = Date()
        let context = try await E2EContext.make()
        let profile = context.environment.conversationProfile
        let session = context.chat(profile, context.connector("a"))
        try await session.start()
        let outbox = try Outbox(directory: try context.outboxDirectory(), submitter: session, diagnostics: context.diagnostics)
        let text = "private-note \(nonce("leak"))"
        let queued = try await outbox.enqueue(botID: profile, text: text)
        _ = await outbox.deliver(queued.submissionID)
        try await waitUntil("the reply") {
            let transcript = await session.transcript
            return turnIsSettled(transcript) && conversation(transcript).contains { $0.content == text }
        }
        let reply = try #require(await session.transcript.assistantTexts.last)
        await session.close()

        let echoedError = GatewayTransportError.rpc(RPCError(
            code: -32603,
            message: "failed on \(text)",
            data: ["reason": "storage_unavailable", "detail": .string(text), "echo": .string(reply)]
        ))
        let failing = try Outbox(
            directory: try context.outboxDirectory(),
            submitter: EchoingErrorSubmitter(error: echoedError),
            diagnostics: context.diagnostics
        )
        let failed = try await failing.enqueue(botID: profile, text: text)
        #expect(await failing.deliver(failed.submissionID) == .retryLater)

        let transcript = context.diagnosticRecorder.transcript
        #expect(transcript.contains("code=-32603"), "the injected error path was logged by code")
        #expect(transcript.contains("attached"))
        for secret in [text, reply, queued.submissionID] { #expect(!transcript.contains(secret), "diagnostics leaked message content") }
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let entries = try store.getEntries(at: store.position(date: started))
            .compactMap { $0 as? OSLogEntryLog }
            .filter { $0.subsystem == E2EContext.subsystem }
        let systemLog = entries.map(\.composedMessage).joined(separator: "\n")
        #expect(!entries.isEmpty)
        for secret in [text, reply] { #expect(!systemLog.contains(secret), "system log leaked message content") }
    }
}

private struct EchoingErrorSubmitter: OutboxSubmitter {
    let error: GatewayTransportError

    func submit(_ entry: OutboxEntry) async throws -> AdmissionStatus {
        throw error
    }
}

private final class Mutable<Value: Sendable>: Sendable {
    let box: Mutex<Value>

    init(_ value: Value) {
        box = Mutex(value)
    }
}
