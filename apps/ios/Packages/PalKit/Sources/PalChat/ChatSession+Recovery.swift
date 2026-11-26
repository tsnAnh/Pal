import Foundation
import PalDiagnostics
import PalProtocol
import PalTransport

public struct WatchdogPolicy: Sendable {
    public var interval: Duration
    public var maximumInterval: Duration
    public var grace: Duration
    public var probeTimeout: Duration

    public init(
        interval: Duration = .seconds(3),
        maximumInterval: Duration = .seconds(8),
        grace: Duration = .seconds(3),
        probeTimeout: Duration = .seconds(5)
    ) {
        self.interval = interval
        self.maximumInterval = maximumInterval
        self.grace = grace
        self.probeTimeout = probeTimeout
    }
}

struct StreamCounters: Sendable, Equatable {
    var applied = 0
    var duplicate = 0
    var ignored = 0
    var resyncRequested = 0
    var resyncDone = 0
    var resyncFailed = 0
    var subscribeChanges = 0
    var watchdogReconciles = 0

    var summary: String {
        "applied=\(applied) duplicate=\(duplicate) ignored=\(ignored) resync=\(resyncRequested)/\(resyncDone)/\(resyncFailed) "
            + "subscribe=\(subscribeChanges) watchdog=\(watchdogReconciles)"
    }
}

enum StreamProbe: Sendable, Equatable {
    case current
    case behind(String)
    case unreachable(String)
}

extension ChatSession {
    public func setWatching(_ on: Bool) {
        guard watching != on else { return }
        watching = on
        if on { restartWatchdogNow() }
    }

    public func setForeground(_ active: Bool) {
        guard foreground != active else { return }
        foreground = active
        if active { restartWatchdogNow() }
    }

    func noteStream(_ event: String, _ detail: String? = nil) {
        let suffix = detail.map { " \($0)" } ?? ""
        diagnostics.notice("chat", "stream \(event)\(suffix) \(counters.summary)")
        ChatOpenTrace.mark(profile, "stream.\(event)", detail: detail)
    }

    func noteSubscribe(_ state: String) {
        counters.subscribeChanges += 1
        noteStream("subscribe", state)
    }

    func noteFrame(_ outcome: ApplyOutcome, _ frame: SessionEventFrame) {
        if case .sessionInfo(let info) = frame.event, let pending = info.pending, let api, let sessionID = transcript.sessionID {
            api.releaseStuck(pending, sessionID: sessionID, diagnostics: diagnostics)
        }
        switch outcome {
        case .applied:
            counters.applied += 1
            lastIgnoredReason = nil
        case .duplicate:
            counters.duplicate += 1
        case .ignored:
            counters.ignored += 1
            let reason = ignoreReason(of: frame)
            if reason != lastIgnoredReason {
                lastIgnoredReason = reason
                noteStream("frame.ignored", reason)
            }
        case .resyncRequired(let reason):
            counters.resyncRequested += 1
            noteStream("resync.requested", "\(reason)")
        }
    }

    private func ignoreReason(of frame: SessionEventFrame) -> String {
        guard let sessionID = frame.sessionID, !sessionID.isEmpty else { return "no-session" }
        if let known = transcript.sessionID, known != sessionID { return "other-session" }
        if transcript.resyncRequested { return "resync-pending" }
        return "no-seq-epoch"
    }

    func startWatchdog(_ connection: GatewayConnection, immediately: Bool = false) {
        watchdog?.cancel()
        guard !closing else {
            watchdog = nil
            return
        }
        watchdog = Task { await self.runWatchdog(connection, immediately: immediately) }
    }

    private func restartWatchdogNow() {
        guard let connection else { return }
        startWatchdog(connection, immediately: true)
    }

    private func runWatchdog(_ connection: GatewayConnection, immediately: Bool) async {
        let policy = watchdogPolicy
        var interval = policy.interval
        var wait = immediately ? Duration.zero : interval
        var stalled: (sequence: Int, since: ContinuousClock.Instant)?
        while !Task.isCancelled {
            try? await Task.sleep(for: wait)
            wait = interval
            guard !Task.isCancelled, !closing, self.connection === connection else { return }
            guard watching, foreground, case .live = phase, let api,
                  let sessionID = transcript.sessionID, let cursor = transcript.cursor
            else {
                stalled = nil
                interval = policy.interval
                wait = interval
                continue
            }
            let verdict = await probe(api, sessionID: sessionID, cursor: cursor)
            guard !Task.isCancelled else { return }
            switch verdict {
            case .current:
                stalled = nil
                staleStrikes = 0
                interval = min(interval * 2, policy.maximumInterval)
                wait = interval
            case .behind(let reason), .unreachable(let reason):
                interval = policy.interval
                wait = interval
                let now = ContinuousClock.now
                let since = stalled.flatMap { $0.sequence == cursor.lastSequence ? $0.since : nil } ?? now
                stalled = (cursor.lastSequence, since)
                guard now - since >= policy.grace * (1 << min(staleStrikes, 4)) else { continue }
                await recoverStale(reason, connection: connection)
                return
            }
        }
    }

    private func recoverStale(_ reason: String, connection: GatewayConnection) async {
        guard !closing, self.connection === connection else { return }
        staleStrikes += 1
        counters.watchdogReconciles += 1
        noteStream("watchdog.reconcile", reason)
        transcript.requestResync()
        await connection.close()
    }

    private func probe(_ api: SessionAPI, sessionID: String, cursor: StreamCursor) async -> StreamProbe {
        let timeout = watchdogPolicy.probeTimeout
        return await withTaskGroup(of: StreamProbe.self) { group in
            group.addTask {
                do {
                    let since = try await api.eventsSince(
                        sessionID: sessionID, lastSequence: cursor.lastSequence, replayEpoch: cursor.replayEpoch
                    )
                    return Self.verdict(since, cursor: cursor)
                } catch {
                    return .unreachable("unreachable \(Diagnostics.describe(error))")
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return .unreachable("unreachable timed out")
            }
            let first = await group.next() ?? .unreachable("unreachable no answer")
            group.cancelAll()
            return first
        }
    }

    nonisolated static func verdict(_ since: EventsSinceResult, cursor: StreamCursor) -> StreamProbe {
        if since.snapshotRequired { return .behind("snapshot-required") }
        if since.replayEpoch != cursor.replayEpoch { return .behind("epoch-changed") }
        if since.latestSeq > cursor.lastSequence { return .behind("gateway-ahead") }
        if since.latestSeq < cursor.lastSequence { return .behind("gateway-regressed") }
        return .current
    }
}
