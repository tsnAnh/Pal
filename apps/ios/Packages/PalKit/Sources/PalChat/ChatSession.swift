import Foundation
import PalAuth
import PalClient
import PalDiagnostics
import PalProtocol
import PalREST
import PalTransport

public enum ChatPhase: Sendable, Equatable {
    case detached
    case attaching
    case live(lastSequence: Int, replayEpoch: String)
    case resyncing
}

public enum ChatUpdate: Sendable {
    case phase(ChatPhase)
    case botThreadLinks([BotThreadLink])
}

public struct ReconnectPolicy: Sendable {
    public var initialDelay: Duration
    public var maximumDelay: Duration

    public init(initialDelay: Duration = .milliseconds(250), maximumDelay: Duration = .seconds(8)) {
        self.initialDelay = initialDelay
        self.maximumDelay = maximumDelay
    }
}

public struct PagingPolicy: Sendable {
    public var firstPage: Int
    public var olderPage: Int
    public var fillPage: Int
    public var fillPages: Int
    public var freshness: Duration
    public var retryBase: TimeInterval
    public var retryMax: TimeInterval

    public init(
        firstPage: Int = 40,
        olderPage: Int = 40,
        fillPage: Int = 100,
        fillPages: Int = 10,
        freshness: Duration = .milliseconds(500),
        retryBase: TimeInterval = 0.5,
        retryMax: TimeInterval = 16
    ) {
        self.firstPage = firstPage
        self.olderPage = olderPage
        self.fillPage = fillPage
        self.fillPages = fillPages
        self.freshness = freshness
        self.retryBase = retryBase
        self.retryMax = retryMax
    }

    func backoff(_ attempt: Int) -> TimeInterval {
        min(retryMax, retryBase * pow(2, Double(max(0, attempt - 1))))
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

struct ChatState: Sendable {
    let phase: ChatPhase
    let transcript: Transcript
}

public actor ChatSession: OutboxSubmitter {
    public nonisolated let profile: String
    public nonisolated let updates: AsyncStream<ChatUpdate>

    public private(set) var phase: ChatPhase = .detached
    private(set) var transcript = Transcript()
    public private(set) var terminalFailure: ChatTerminalFailure?
    public private(set) var botThreadLinks: [BotThreadLink] = []
    public nonisolated let terminalFailures: AsyncStream<ChatTerminalFailure>
    public nonisolated let timelineSnapshots: AsyncStream<TimelineSnapshot>

    private static let botThreadsChangedEvent = "bot_threads.changed"
    private static let messageCompleteEvent = "message.complete"

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
    private var linksRefresh: Task<Void, Never>?
    private var linksStale = false
    private var waiters: [UUID: StateWaiter] = [:]
    private let paging: PagingPolicy
    private let timelineContinuation: AsyncStream<TimelineSnapshot>.Continuation
    private var timeline = Timeline()
    private var timelineVersion: UInt64 = 0
    private var timelineCapable = false
    private var lastWant: ContinuousClock.Instant?
    private var wantSerial = 0
    private var olderLoader: Task<Void, Never>?
    private var olderFetch: Task<OlderFetch, Never>?
    private var newestRefresh: Task<Void, Never>?
    private var newestStale = false

    private enum OlderFetch: Sendable {
        case loaded
        case failed
    }

    private struct StateWaiter {
        let isSatisfied: @Sendable (ChatState) -> Bool
        let continuation: CheckedContinuation<ChatState?, Never>
    }

    public init(
        profile: String,
        connector: any ChatConnector,
        reconnectPolicy: ReconnectPolicy = ReconnectPolicy(),
        paging: PagingPolicy = PagingPolicy(),
        diagnostics: Diagnostics = .silent
    ) {
        self.profile = profile
        self.paging = paging
        (timelineSnapshots, timelineContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
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
            let capable = api.supportsTimeline
            resolution = try await resolver.open(api, timelineLimit: capable ? paging.firstPage : nil)
            timelineCapable = capable
            try await adoptTimeline(resolution.snapshot, page: resolution.timeline, api: api, forced: false)
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
        guard let intro, resolution.created || (resolution.timeline?.entries ?? []).isEmpty && resolution.snapshot.messages.isEmpty else {
            return ChatStartOutcome(created: resolution.created, introAdmission: nil)
        }
        do {
            let admission = try await submitText(
                intro.text,
                submissionID: "intro:\(resolution.snapshot.sessionID)",
                hidden: intro.hidden,
                echo: !intro.hidden
            )
            return ChatStartOutcome(created: resolution.created, introAdmission: admission)
        } catch {
            diagnostics.warning("chat", "intro was not admitted: \(Diagnostics.describe(error))")
            return ChatStartOutcome(created: resolution.created, introAdmission: nil)
        }
    }

    public func submit(_ entry: OutboxEntry, files: [OutgoingFile]) async throws -> AdmissionStatus {
        try await submitText(
            entry.text,
            submissionID: entry.submissionID,
            attachments: entry.attachments,
            files: files,
            hidden: false,
            echo: true
        )
    }

    @discardableResult
    public func submitVoiceTurn(_ text: String) async throws -> AdmissionStatus {
        try await submitText(
            text,
            submissionID: "voice:\(UUID().uuidString)",
            hidden: false,
            echo: true,
            voiceTurn: true
        )
    }

    public func slashCommands() async throws -> [SlashItem] {
        guard case .live = phase, let api, let sessionID = transcript.sessionID else { throw ChatError.notConnected }
        return try await api.slashCommands(sessionID: sessionID)
    }

    public func pathCompletions(word: String) async throws -> [FileRefItem] {
        guard case .live = phase, let api, let sessionID = transcript.sessionID else { throw ChatError.notConnected }
        return try await api.pathCompletions(sessionID: sessionID, word: word)
    }

    public func attachImage(_ data: Data, filename: String) async throws -> StagedImage {
        guard case .live = phase, let api, let sessionID = transcript.sessionID else { throw ChatError.notConnected }
        return try await api.attachImage(sessionID: sessionID, data: data, filename: filename)
    }

    public func imageAsset(ref: String, thumbnail: Bool) async throws -> Data {
        if api == nil { _ = await awaitState { if case .live = $0.phase { true } else { false } } }
        try Task.checkCancellation()
        guard let api else { throw ChatError.notConnected }
        return try await api.libraryAsset(ref: ref, thumbnail: thumbnail)
    }

    public func attachFile(_ data: Data, name: String, mime: String) async throws -> StagedFile {
        guard case .live = phase, let api, let sessionID = transcript.sessionID else { throw ChatError.notConnected }
        return try await api.attachFile(sessionID: sessionID, data: data, name: name, mime: mime)
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

    public func react(to target: ReactionTarget, emoji: String?) async throws -> String? {
        guard case .live = phase, let api, let sessionID = transcript.sessionID else { throw ChatError.notConnected }
        return try await api.react(sessionID: sessionID, target: target, emoji: emoji)
    }

    public func answerApproval(_ prompt: PendingPrompt, choice: String) async throws {
        guard case .live = phase, let api, let sessionID = transcript.sessionID else { throw ChatError.notConnected }
        transcript.noteApprovalChoice(choice, promptID: prompt.promptID)
        timeline.noteApprovalChoice(choice, promptID: prompt.promptID)
        do {
            _ = try await api.respondToApproval(
                sessionID: sessionID,
                executionGeneration: prompt.executionGeneration,
                promptID: prompt.promptID,
                choice: choice
            )
        } catch {
            transcript.noteApprovalChoice(nil, promptID: prompt.promptID)
            timeline.noteApprovalChoice(nil, promptID: prompt.promptID)
            throw error
        }
    }

    public func interrupt() async throws {
        guard case .live = phase, let api, let sessionID = transcript.sessionID else { throw ChatError.notConnected }
        try await api.interrupt(sessionID: sessionID, executionGeneration: transcript.executionGeneration)
    }

    public func steer(_ text: String) async throws -> SteerStatus {
        guard case .live = phase, let api, let sessionID = transcript.sessionID else { throw ChatError.notConnected }
        return try await api.steer(sessionID: sessionID, text: text, executionGeneration: transcript.executionGeneration)
    }

    var state: ChatState { ChatState(phase: phase, transcript: transcript) }

    public func settledPhase() async -> ChatPhase? {
        await awaitState { $0.phase != .attaching }?.phase
    }

    func awaitState(where isSatisfied: @escaping @Sendable (ChatState) -> Bool) async -> ChatState? {
        if isSatisfied(state) { return state }
        if closing { return nil }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters[id] = StateWaiter(isSatisfied: isSatisfied, continuation: continuation)
            }
        } onCancel: {
            Task { await self.dropWaiter(id) }
        }
    }

    private func dropWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.continuation.resume(returning: nil)
    }

    private func notifyWaiters() {
        let current = state
        for (id, waiter) in waiters where waiter.isSatisfied(current) {
            waiters[id] = nil
            waiter.continuation.resume(returning: current)
        }
    }

    public func close() {
        closing = true
        let abandoned = waiters.values
        waiters = [:]
        for waiter in abandoned { waiter.continuation.resume(returning: nil) }
        for pump in pumps { pump.cancel() }
        pumps.removeAll()
        linksRefresh?.cancel()
        linksRefresh = nil
        for task in [olderLoader, newestRefresh].compactMap({ $0 }) { task.cancel() }
        olderFetch?.cancel()
        olderLoader = nil
        newestRefresh = nil
        timelineContinuation.finish()
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
        attachments: [PromptAttachment] = [],
        files: [OutgoingFile] = [],
        hidden: Bool,
        echo: Bool,
        voiceTurn: Bool = false
    ) async throws -> AdmissionStatus {
        guard case .live = phase, let api, let sessionID = transcript.sessionID else { throw ChatError.notConnected }
        if echo {
            let echoed = text.isEmpty ? files.map(\.name).joined(separator: ", ") : text
            transcript.echoUser(submissionID: submissionID, text: echoed)
            timeline.echoUser(submissionID: submissionID, text: echoed)
            publishTimeline()
            notifyWaiters()
        }
        do {
            return try await api.submit(
                sessionID: sessionID,
                text: text,
                submissionID: submissionID,
                attachments: attachments,
                files: files,
                hidden: hidden,
                voiceTurn: voiceTurn
            )
        } catch {
            if echo, let refusal = RefusalReason(error), refusal.isPermanent {
                transcript.markFailed(submissionID: submissionID, reason: refusal.reason)
                timeline.markFailed(submissionID: submissionID, reason: refusal.reason)
                publishTimeline()
                notifyWaiters()
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
        refreshBotThreadLinks()
    }

    private func refreshBotThreadLinks() {
        guard !closing else { return }
        guard linksRefresh == nil else {
            linksStale = true
            return
        }
        linksRefresh = Task { await self.runLinksRefresh() }
    }

    private func runLinksRefresh() async {
        repeat {
            linksStale = false
            guard !closing, let api, let sessionID = transcript.sessionID else { break }
            do {
                let result = try await api.botThreadLinks(sessionID: sessionID)
                guard !closing else { break }
                if result.links != botThreadLinks {
                    botThreadLinks = result.links
                    continuation.yield(.botThreadLinks(result.links))
                    publishTimeline()
                }
            } catch {
                diagnostics.debug("chat", "bot thread links unavailable: \(Diagnostics.describe(error))")
            }
        } while linksStale && !closing
        linksRefresh = nil
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
        if event.type == Self.botThreadsChangedEvent {
            refreshBotThreadLinks()
            return true
        }
        let frame = SessionEventFrame(event)
        _ = timeline.apply(frame)
        switch transcript.apply(frame) {
        case .applied:
            publishLive()
            if event.type == Self.messageCompleteEvent {
                refreshBotThreadLinks()
                refreshNewest()
            }
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
            let resumed = try await resumeForTimeline(api, sessionID)
            transcript.requestResync()
            _ = transcript.reconcile(with: resumed.snapshot)
            try await adoptTimeline(resumed.snapshot, page: resumed.timeline, api: api, forced: true)
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
        case SignInError.notSignedIn, PalClientError.notSignedIn: .notSignedIn
        case SignInError.sessionExpired, RESTError.unauthorized: .sessionExpired
        case GatewayTransportError.closed(.forbidden): .accessForbidden
        default: nil
        }
    }

    private func reattach(_ api: SessionAPI) async throws {
        timelineCapable = api.supportsTimeline
        guard let row = try await resolver.lookup(api) else {
            let resolution = try await resolver.open(api, timelineLimit: timelineCapable ? paging.firstPage : nil)
            transcript.requestResync()
            _ = transcript.reconcile(with: resolution.snapshot)
            try await adoptTimeline(resolution.snapshot, page: resolution.timeline, api: api, forced: true)
            return
        }
        let target = BotChatResolver.target(of: row)
        guard target == transcript.sessionID, let cursor = transcript.cursor, !transcript.resyncRequested else {
            let resumed = try await resumeForTimeline(api, target)
            transcript.requestResync()
            _ = transcript.reconcile(with: resumed.snapshot)
            try await adoptTimeline(resumed.snapshot, page: resumed.timeline, api: api, forced: true)
            return
        }
        let since = try await api.eventsSince(sessionID: target, lastSequence: cursor.lastSequence, replayEpoch: cursor.replayEpoch)
        if since.snapshotRequired {
            setPhase(.resyncing)
            let resumed = try await resumeForTimeline(api, target)
            transcript.requestResync()
            _ = transcript.reconcile(with: resumed.snapshot)
            try await adoptTimeline(resumed.snapshot, page: resumed.timeline, api: api, forced: true)
            return
        }
        for raw in since.events {
            guard let event = GatewayEvent(params: raw) else { continue }
            let frame = SessionEventFrame(event)
            _ = timeline.apply(frame)
            if case .resyncRequired = transcript.apply(frame) { break }
        }
        let resumed = try await resumeForTimeline(api, target)
        _ = transcript.reconcile(with: resumed.snapshot)
        try await adoptTimeline(resumed.snapshot, page: resumed.timeline, api: api, forced: false)
    }

    private func resumeForTimeline(_ api: SessionAPI, _ sessionID: String) async throws -> TimelineResume {
        try await api.resumeTimeline(sessionID: sessionID, timelineLimit: paging.firstPage)
    }

    private func adoptTimeline(_ snapshot: SessionSnapshot, page: TimelinePageWire?, api: SessionAPI, forced: Bool) async throws {
        if forced { timeline.forceLive(snapshot) } else { timeline.adoptLive(snapshot) }
        guard timelineCapable else {
            timeline.mergeNewest(TimelinePageWire(entries: Timeline.legacyEntries(snapshot.messages), older: nil, revision: ""))
            return
        }
        try await mergeNewest(page ?? TimelinePageWire(entries: [], older: nil, revision: ""), api: api, sessionID: snapshot.sessionID)
    }

    private func mergeNewest(_ page: TimelinePageWire, api: SessionAPI, sessionID: String) async throws {
        guard case .gap(var cursor) = timeline.mergeNewest(page) else { return }
        var collected = page.entries
        for _ in 0..<paging.fillPages {
            let older = try await api.timelinePage(sessionID: sessionID, before: cursor, limit: paging.fillPage)
            collected = older.entries + collected
            let reached = older.entries.contains { timeline.contains(entryID: $0.id) }
            guard !reached, let next = older.older else {
                timeline.mergeNewest(TimelinePageWire(entries: collected, older: older.older, revision: page.revision))
                return
            }
            cursor = next
        }
        diagnostics.info("chat", "timeline gap too wide to fill; showing the newest page")
        timeline.reset(page)
    }

    private func refreshNewest() {
        guard timelineCapable, !closing else { return }
        guard newestRefresh == nil else {
            newestStale = true
            return
        }
        newestRefresh = Task { await self.runNewestRefresh() }
    }

    private func runNewestRefresh() async {
        repeat {
            newestStale = false
            guard !closing, let api, let sessionID = transcript.sessionID else { break }
            do {
                let page = try await api.timelinePage(sessionID: sessionID, before: nil, limit: paging.firstPage)
                guard !closing else { break }
                try await mergeNewest(page, api: api, sessionID: sessionID)
                publishTimeline()
            } catch {
                diagnostics.debug("chat", "newest timeline page unavailable: \(Diagnostics.describe(error))")
            }
        } while newestStale && !closing
        newestRefresh = nil
    }

    public var timelineSnapshot: TimelineSnapshot { makeTimelineSnapshot() }

    public func seed(_ cache: CachedTimeline) {
        guard transcript.sessionID == nil || transcript.sessionID == cache.sessionID else { return }
        timeline.seed(cache)
        publishTimeline()
    }

    public func cachedTimeline() -> CachedTimeline? {
        guard let sessionID = transcript.sessionID else { return nil }
        return timeline.cacheable(sessionID: sessionID)
    }

    public func wantOlder() {
        guard !closing else { return }
        lastWant = .now
        wantSerial += 1
        guard olderLoader == nil else { return }
        olderLoader = Task { await self.runOlderLoader() }
    }

    public func reveal(matching predicate: @Sendable (ChatTimelineRow) -> Bool) async -> RowKey? {
        while !closing, !Task.isCancelled {
            if let row = timeline.rows(links: botThreadLinks).first(where: predicate) { return row.id }
            guard let outcome = await fetchOlder(), case .loaded = outcome else { return nil }
        }
        return nil
    }

    private var wantIsFresh: Bool {
        lastWant.map { ContinuousClock.now - $0 <= paging.freshness } ?? false
    }

    private var shownRowCount: Int { timeline.rows(links: botThreadLinks).count }

    private func runOlderLoader() async {
        while !closing, !Task.isCancelled {
            if case .failed(_, let retryAt, _) = timeline.older {
                guard wantIsFresh else { break }
                let wait = retryAt.timeIntervalSinceNow
                if wait > 0 {
                    try? await Task.sleep(for: .milliseconds(Int(wait * 1000) + 1))
                    continue
                }
            }
            let serial = wantSerial
            let before = shownRowCount
            guard let outcome = await fetchOlder() else { break }
            if case .loaded = outcome, shownRowCount > before, wantSerial == serial || !wantIsFresh { break }
        }
        olderLoader = nil
    }

    private func fetchOlder() async -> OlderFetch? {
        if let inFlight = olderFetch { return await inFlight.value }
        guard timelineCapable, let api, let sessionID = transcript.sessionID,
              let cursor = timeline.beginLoadingOlder(now: Date())
        else { return nil }
        publishTimeline()
        let task = Task { await self.performOlderFetch(api: api, sessionID: sessionID, cursor: cursor) }
        olderFetch = task
        let outcome = await task.value
        olderFetch = nil
        return outcome
    }

    private func performOlderFetch(api: SessionAPI, sessionID: String, cursor: String) async -> OlderFetch {
        do {
            let page = try await api.timelinePage(sessionID: sessionID, before: cursor, limit: paging.olderPage)
            if timeline.prepend(page, requested: cursor) { publishTimeline() }
            return .loaded
        } catch let error as GatewayTransportError where error.isCursorStale {
            diagnostics.info("chat", "older cursor went stale; reloading the newest page")
            do {
                let page = try await api.timelinePage(sessionID: sessionID, before: nil, limit: paging.firstPage)
                timeline.reset(page)
                publishTimeline()
                return .loaded
            } catch {
                return failOlder(cursor: cursor, error)
            }
        } catch {
            return failOlder(cursor: cursor, error)
        }
    }

    private func failOlder(cursor: String, _ error: any Error) -> OlderFetch {
        diagnostics.debug("chat", "older timeline page failed: \(Diagnostics.describe(error))")
        timeline.failOlder(requested: cursor, now: Date(), backoff: paging.backoff)
        publishTimeline()
        return .failed
    }

    private func makeTimelineSnapshot() -> TimelineSnapshot {
        TimelineSnapshot(
            version: timelineVersion,
            sessionID: timeline.live.sessionID,
            rows: timeline.rows(links: botThreadLinks),
            older: timeline.older.state,
            isRunning: timeline.live.isRunning,
            pendingPrompts: timeline.live.pendingPrompts,
            lastError: timeline.live.lastError,
            executionGeneration: timeline.live.executionGeneration,
            runningToolName: timeline.live.runningToolName,
            streamingText: timeline.live.streamingText
        )
    }

    private func publishTimeline() {
        timelineVersion += 1
        timelineContinuation.yield(makeTimelineSnapshot())
    }

    private func setPhase(_ next: ChatPhase) {
        phase = next
        continuation.yield(.phase(next))
        notifyWaiters()
    }

    private func publishLive() {
        if let cursor = transcript.cursor {
            phase = .live(lastSequence: cursor.lastSequence, replayEpoch: cursor.replayEpoch)
            continuation.yield(.phase(phase))
        }
        publishTimeline()
        notifyWaiters()
    }
}
