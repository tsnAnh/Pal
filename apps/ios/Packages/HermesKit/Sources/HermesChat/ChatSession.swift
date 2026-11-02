import Foundation
import HermesAuth
import HermesClient
import HermesDiagnostics
import HermesProtocol
import HermesREST
import HermesTransport

public enum ChatPhase: Sendable, Equatable {
    case detached
    case attaching
    case live(lastSequence: Int, replayEpoch: String)
    case resyncing
}

public enum ChatUpdate: Sendable {
    case phase(ChatPhase)
    case transcript(Transcript)
}

public struct ReconnectPolicy: Sendable {
    public var initialDelay: Duration
    public var maximumDelay: Duration

    public init(initialDelay: Duration = .milliseconds(250), maximumDelay: Duration = .seconds(8)) {
        self.initialDelay = initialDelay
        self.maximumDelay = maximumDelay
    }
}

public enum ChatTerminalFailure: Sendable, Equatable {
    case notSignedIn
    case sessionExpired
    case accessForbidden
}

public struct ChatStartOutcome: Sendable, Equatable {
    public var created: Bool
    public var introAdmission: AdmissionStatus?
}

public actor ChatSession: OutboxSubmitter {
    public nonisolated let profile: String
    public nonisolated let updates: AsyncStream<ChatUpdate>

    public private(set) var phase: ChatPhase = .detached
    public private(set) var transcript = Transcript()
    public private(set) var terminalFailure: ChatTerminalFailure?
    public nonisolated let terminalFailures: AsyncStream<ChatTerminalFailure>

    private let continuation: AsyncStream<ChatUpdate>.Continuation
    private let failureContinuation: AsyncStream<ChatTerminalFailure>.Continuation
    private let connector: any ChatConnector
    private let resolver: BotChatResolver
    private let diagnostics: Diagnostics
    private let reconnectPolicy: ReconnectPolicy
    private var connection: GatewayConnection?
    private var attaching: GatewayConnection?
    private var api: SessionAPI?
    private var pumps: [Task<Void, Never>] = []
    private var reconnecting = false
    private var closing = false

    public init(
        profile: String,
        connector: any ChatConnector,
        reconnectPolicy: ReconnectPolicy = ReconnectPolicy(),
        diagnostics: Diagnostics = .silent
    ) {
        self.profile = profile
        self.connector = connector
        self.reconnectPolicy = reconnectPolicy
        self.diagnostics = diagnostics
        resolver = BotChatResolver(diagnostics: diagnostics)
        (updates, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(64))
        (terminalFailures, failureContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(4))
    }

    @discardableResult
    public func start(intro: BotIntro? = nil) async throws -> ChatStartOutcome {
        let idle = ChatStartOutcome(created: false, introAdmission: nil)
        guard phase == .detached, !closing else { return idle }
        terminalFailure = nil
        setPhase(.attaching)
        let connection: GatewayConnection
        do {
            connection = try await connector.connect()
        } catch {
            setPhase(.detached)
            noteTerminal(error)
            throw error
        }
        if closing {
            await connection.close()
            setPhase(.detached)
            return idle
        }
        let resolution: BotChatResolution
        let api = SessionAPI(connection: connection, profile: profile)
        attaching = connection
        do {
            resolution = try await resolver.open(api)
        } catch {
            attaching = nil
            await connection.close()
            setPhase(.detached)
            if closing { return idle }
            noteTerminal(error)
            throw error
        }
        attaching = nil
        if closing {
            await connection.close()
            setPhase(.detached)
            return idle
        }
        self.api = api
        self.connection = connection
        _ = transcript.reconcile(with: resolution.snapshot)
        diagnostics.info("chat", "attached; \(transcript.items.count) items")
        goLive(connection)
        guard let intro, resolution.created || resolution.snapshot.messages.isEmpty else {
            return ChatStartOutcome(created: resolution.created, introAdmission: nil)
        }
        do {
            let admission = try await submitText(
                intro.text,
                submissionID: "intro:\(resolution.snapshot.sessionID)",
                attachments: [],
                hidden: intro.hidden,
                echo: !intro.hidden
            )
            return ChatStartOutcome(created: resolution.created, introAdmission: admission)
        } catch {
            diagnostics.warning("chat", "intro was not admitted: \(Diagnostics.describe(error))")
            return ChatStartOutcome(created: resolution.created, introAdmission: nil)
        }
    }

    public func submit(_ entry: OutboxEntry) async throws -> AdmissionStatus {
        try await submitText(entry.text, submissionID: entry.submissionID, attachments: entry.attachments, hidden: false, echo: true)
    }

    public func answerClarify(_ prompt: PendingPrompt, answer: String) async throws {
        guard case .live = phase, let api, let sessionID = transcript.sessionID else { throw ChatError.notConnected }
        _ = try await api.respondToClarify(
            sessionID: sessionID,
            executionGeneration: prompt.executionGeneration,
            promptID: prompt.promptID,
            answer: answer
        )
    }

    public func answerApproval(_ prompt: PendingPrompt, choice: String) async throws {
        guard case .live = phase, let api, let sessionID = transcript.sessionID else { throw ChatError.notConnected }
        _ = try await api.respondToApproval(
            sessionID: sessionID,
            executionGeneration: prompt.executionGeneration,
            promptID: prompt.promptID,
            choice: choice
        )
    }

    public func close() {
        closing = true
        for pump in pumps { pump.cancel() }
        pumps.removeAll()
        let connection = self.connection
        let unattached = attaching
        attaching = nil
        self.connection = nil
        api = nil
        phase = .detached
        continuation.yield(.phase(.detached))
        continuation.finish()
        failureContinuation.finish()
        for doomed in [connection, unattached].compactMap({ $0 }) { Task { await doomed.close() } }
    }

    private func submitText(
        _ text: String,
        submissionID: String,
        attachments: [PromptAttachment],
        hidden: Bool,
        echo: Bool
    ) async throws -> AdmissionStatus {
        guard case .live = phase, let api, let sessionID = transcript.sessionID else { throw ChatError.notConnected }
        if echo {
            transcript.echoUser(submissionID: submissionID, text: text)
            continuation.yield(.transcript(transcript))
        }
        do {
            return try await api.submit(
                sessionID: sessionID,
                text: text,
                submissionID: submissionID,
                attachments: attachments,
                hidden: hidden
            )
        } catch {
            if echo, let refusal = RefusalReason(error), refusal.isPermanent {
                transcript.markFailed(submissionID: submissionID, reason: refusal.reason)
                continuation.yield(.transcript(transcript))
            }
            throw error
        }
    }

    private func goLive(_ connection: GatewayConnection) {
        publishLive()
        pumps = [
            Task { await self.consume(connection) },
            Task { await self.rejectServerRequests(connection) },
        ]
    }

    private func rejectServerRequests(_ connection: GatewayConnection) async {
        for await request in connection.serverRequests {
            diagnostics.debug("chat", "rejected server request \(request.method)")
            await connection.reject(request.id, code: -32601, message: "unsupported")
        }
    }

    private func consume(_ connection: GatewayConnection) async {
        for await event in connection.events {
            guard !Task.isCancelled, !closing, self.connection === connection else { return }
            guard await handle(event) else {
                await connection.close()
                await reconnect()
                return
            }
        }
        guard !closing, self.connection === connection else { return }
        await reconnect()
    }

    private func handle(_ event: GatewayEvent) async -> Bool {
        switch transcript.apply(SessionEventFrame(event)) {
        case .applied:
            publishLive()
        case .resyncRequired(let reason):
            diagnostics.info("chat", "resync required (\(reason))")
            return await resync()
        case .duplicate, .ignored:
            break
        }
        return true
    }

    private func resync() async -> Bool {
        guard let api, let sessionID = transcript.sessionID else { return false }
        setPhase(.resyncing)
        do {
            let snapshot = try await api.resume(sessionID: sessionID)
            transcript.requestResync()
            _ = transcript.reconcile(with: snapshot)
            publishLive()
            return true
        } catch {
            diagnostics.warning("chat", "resync failed: \(Diagnostics.describe(error))")
            return false
        }
    }

    private func reconnect() async {
        guard !reconnecting, !closing else { return }
        reconnecting = true
        defer { reconnecting = false }
        setPhase(.attaching)
        connection = nil
        api = nil
        var delay = reconnectPolicy.initialDelay
        while !closing {
            var candidate: GatewayConnection?
            do {
                let fresh = try await connector.connect()
                candidate = fresh
                let freshAPI = SessionAPI(connection: fresh, profile: profile)
                try await reattach(freshAPI)
                guard !closing else {
                    await fresh.close()
                    return
                }
                connection = fresh
                api = freshAPI
                diagnostics.info("chat", "reattached; \(transcript.items.count) items")
                goLive(fresh)
                return
            } catch {
                if let candidate { await candidate.close() }
                if noteTerminal(error) {
                    diagnostics.warning("chat", "reattach stopped: \(Diagnostics.describe(error))")
                    setPhase(.detached)
                    return
                }
                diagnostics.warning("chat", "reattach failed: \(Diagnostics.describe(error))")
                try? await Task.sleep(for: delay)
                delay = min(delay * 2, reconnectPolicy.maximumDelay)
            }
        }
    }

    @discardableResult
    private func noteTerminal(_ error: any Error) -> Bool {
        guard let failure = Self.terminalFailure(of: error) else { return false }
        terminalFailure = failure
        failureContinuation.yield(failure)
        return true
    }

    static func terminalFailure(of error: any Error) -> ChatTerminalFailure? {
        switch error {
        case SignInError.notSignedIn, HermesClientError.notSignedIn: .notSignedIn
        case SignInError.sessionExpired, RESTError.unauthorized: .sessionExpired
        case GatewayTransportError.closed(.forbidden): .accessForbidden
        case GatewayTransportError.handshakeRejected(let status):
            switch status {
            case 401: .sessionExpired
            case 403: .accessForbidden
            default: nil
            }
        default: nil
        }
    }

    private func reattach(_ api: SessionAPI) async throws {
        guard let row = try await resolver.lookup(api) else {
            let resolution = try await resolver.open(api)
            transcript.requestResync()
            _ = transcript.reconcile(with: resolution.snapshot)
            return
        }
        let target = BotChatResolver.target(of: row)
        guard target == transcript.sessionID, let cursor = transcript.cursor, !transcript.resyncRequested else {
            let snapshot = try await api.resume(sessionID: target)
            transcript.requestResync()
            _ = transcript.reconcile(with: snapshot)
            return
        }
        let since = try await api.eventsSince(sessionID: target, lastSequence: cursor.lastSequence, replayEpoch: cursor.replayEpoch)
        if since.snapshotRequired {
            setPhase(.resyncing)
            let snapshot = try await api.resume(sessionID: target)
            transcript.requestResync()
            _ = transcript.reconcile(with: snapshot)
            return
        }
        for raw in since.events {
            guard let event = GatewayEvent(params: raw) else { continue }
            if case .resyncRequired = transcript.apply(SessionEventFrame(event)) { break }
        }
        _ = transcript.reconcile(with: try await api.resume(sessionID: target))
    }

    private func setPhase(_ next: ChatPhase) {
        phase = next
        continuation.yield(.phase(next))
    }

    private func publishLive() {
        if let cursor = transcript.cursor {
            phase = .live(lastSequence: cursor.lastSequence, replayEpoch: cursor.replayEpoch)
            continuation.yield(.phase(phase))
        }
        continuation.yield(.transcript(transcript))
    }
}
