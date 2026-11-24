@testable import PalChat
import Foundation
import PalDiagnostics
import PalProtocol
import Synchronization
import Testing

private let quietWatchdog = WatchdogPolicy(interval: .seconds(60), maximumInterval: .seconds(60), grace: .seconds(60))
private let fastWatchdog = WatchdogPolicy(
    interval: .milliseconds(100), maximumInterval: .milliseconds(200), grace: .milliseconds(200), probeTimeout: .milliseconds(300)
)
private let fastPaging = PagingPolicy(freshness: .milliseconds(300), retryBase: 0.05, retryMax: 0.2)
private let deadline = Duration.seconds(2)

private final class GatewayProcess: Sendable {
    let script = TimelineScript(entries: entries(1...20))
    private let epoch = Mutex(TimelineScript.epoch)

    func handle(_ method: String, _ params: JSONValue?, _ connection: Int) -> FakeGateway.Reply {
        let reply = script.handle(method, params, connection)
        let current = epoch.withLock { $0 }
        guard current != TimelineScript.epoch, case .result(.object(var object)) = reply else { return reply }
        switch method {
        case "session.resume":
            object["replay_epoch"] = .string(current)
        case "session.events.since":
            object["replay_epoch"] = .string(current)
            object["snapshot_required"] = .bool(params?["replay_epoch"]?.stringValue != current)
        default:
            return reply
        }
        return .result(.object(object))
    }

    func restart() {
        epoch.withLock { $0 = "e2" }
        script.lastSequence.withLock { $0 = 1 }
    }

    func appendReply(sequence: Int, id: String = "u99", text: String = "reply") {
        script.append([TimelineEntryWire(id: id, role: .assistant, text: text, turnID: "t-\(id)", segment: 0)])
        script.lastSequence.withLock { $0 = sequence }
    }

    func setSequence(_ sequence: Int) {
        script.lastSequence.withLock { $0 = sequence }
    }

    func frame(_ type: String, seq: Int, payload: JSONValue) -> JSONValue {
        [
            "type": .string(type),
            "session_id": .string(TimelineScript.sessionID),
            "seq": .int(seq),
            "replay_epoch": .string(epoch.withLock { $0 }),
            "payload": payload,
        ]
    }

    func replyFrame(seq: Int, id: String = "u99", text: String = "reply") -> JSONValue {
        frame("message.complete", seq: seq, payload: ["text": .string(text), "turn_id": .string("t-\(id)"), "message_uid": .string(id)])
    }
}

private struct OpenChat {
    let gateway: FakeGateway
    let process: GatewayProcess
    let session: ChatSession
    let recorder: DiagnosticRecorder

    var notices: [String] { recorder.events.filter { $0.level == .notice }.map(\.message) }

    func finish() async {
        await session.close()
        gateway.stop()
    }
}

private func openChat(watchdog: WatchdogPolicy) async throws -> OpenChat {
    let process = GatewayProcess()
    let gateway = try await FakeGateway.start(process.handle)
    let recorder = DiagnosticRecorder()
    let session = ChatSession(
        profile: "bot",
        connector: process.script.connector(gateway.url),
        reconnectPolicy: ReconnectPolicy(initialDelay: .milliseconds(50), maximumDelay: .milliseconds(200)),
        paging: fastPaging,
        diagnostics: recorder.diagnostics,
        watchdog: watchdog
    )
    try await session.start()
    return OpenChat(gateway: gateway, process: process, session: session, recorder: recorder)
}

private func isLive(_ session: ChatSession, _ expected: ChatPhase) async -> Bool {
    let end = ContinuousClock.now + deadline
    while ContinuousClock.now < end {
        if await session.phase == expected { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return false
}

private func hasReply(_ snapshot: TimelineSnapshot) -> Bool { rowTexts(snapshot).contains("reply") }

private final class SnapshotLog: Sendable {
    let seen = Mutex<[TimelineSnapshot]>([])
}

private final class SnapshotCollector: Sendable {
    private let log = SnapshotLog()
    private let task: Task<Void, Never>

    init(_ stream: AsyncStream<TimelineSnapshot>) {
        let log = log
        task = Task { for await snapshot in stream { log.seen.withLock { $0.append(snapshot) } } }
    }

    var latest: TimelineSnapshot? { log.seen.withLock { $0.last } }

    var versions: [UInt64] { log.seen.withLock { $0.map(\.version) } }

    func stop() async {
        task.cancel()
        await task.value
    }

    func waitFor(_ predicate: @Sendable (TimelineSnapshot) -> Bool) async -> TimelineSnapshot? {
        let end = ContinuousClock.now + deadline
        while ContinuousClock.now < end {
            if let latest, predicate(latest) { return latest }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }
}

private func ownerEntry(_ text: String) -> OutboxEntry {
    OutboxEntry(submissionID: UUID().uuidString, botID: "bot", text: text, attachments: [], createdAt: Date(), state: .pending, attempts: 0)
}

@Suite struct ChatRecoveryTests {
    @Test func aChangedReplayEpochReconcilesAndShowsTheNextReply() async throws {
        let chat = try await openChat(watchdog: quietWatchdog)
        chat.process.restart()
        chat.process.appendReply(sequence: 2)
        chat.gateway.push(chat.process.replyFrame(seq: 2))
        let shown = try #require(await waitForTimeline(chat.session, timeout: deadline, hasReply))
        #expect(rowTexts(shown).filter { $0 == "reply" }.count == 1)
        let live = await isLive(chat.session, .live(lastSequence: 2, replayEpoch: "e2"))
        #expect(live)
        #expect(chat.notices.contains { $0.contains("stream resync.requested epochChanged") })
        #expect(chat.notices.contains { $0.contains("stream resync.done") })
        #expect(!chat.notices.contains { $0.contains("reply") })
        await chat.finish()
    }

    @Test func aReplayGapReconcilesAndShowsTheNextReply() async throws {
        let chat = try await openChat(watchdog: quietWatchdog)
        chat.process.appendReply(sequence: 7)
        chat.gateway.push([
            "type": "session.replay_gap", "session_id": .string(TimelineScript.sessionID), "payload": ["latest_seq": 7],
        ])
        let shown = try #require(await waitForTimeline(chat.session, timeout: deadline, hasReply))
        #expect(rowTexts(shown).filter { $0 == "reply" }.count == 1)
        #expect(chat.notices.contains { $0.contains("stream resync.requested replayGap") })
        await chat.finish()
    }

    @Test func aDroppedSubscriptionResubscribesAndShowsTheNextReply() async throws {
        let chat = try await openChat(watchdog: quietWatchdog)
        chat.process.appendReply(sequence: 2)
        chat.gateway.dropAll()
        let shown = try #require(await waitForTimeline(chat.session, timeout: deadline, hasReply))
        #expect(rowTexts(shown).filter { $0 == "reply" }.count == 1)
        #expect(chat.gateway.connectionCount >= 2)
        #expect(chat.notices.contains { $0.contains("stream subscribe stream-ended") })
        #expect(chat.notices.contains { $0.contains("stream subscribe live") })
        await chat.finish()
    }

    @Test func aFailedFirstResyncIsRetriedUntilItSucceeds() async throws {
        let chat = try await openChat(watchdog: quietWatchdog)
        let resumed = chat.process.script.count("session.resume")
        chat.process.script.override("session.resume") { number in
            number == resumed + 1 ? .failure(RPCError(code: 5000, message: "restarting", data: ["reason": "restarting"])) : nil
        }
        chat.process.restart()
        chat.process.appendReply(sequence: 2)
        chat.gateway.push(chat.process.replyFrame(seq: 2))
        let shown = try #require(await waitForTimeline(chat.session, timeout: deadline, hasReply))
        #expect(rowTexts(shown).filter { $0 == "reply" }.count == 1)
        #expect(chat.notices.contains { $0.contains("stream resync.failed") })
        #expect(chat.notices.contains { $0.contains("stream subscribe handle-failed") })
        let live = await isLive(chat.session, .live(lastSequence: 2, replayEpoch: "e2"))
        #expect(live)
        await chat.finish()
    }

    @Test func aRestartThatDropsTheSubscriptionAndFailsTheFirstResyncStillShowsTheNextReply() async throws {
        let chat = try await openChat(watchdog: quietWatchdog)
        let resumed = chat.process.script.count("session.resume")
        chat.process.script.override("session.resume") { number in
            number == resumed + 1 ? .failure(RPCError(code: 5000, message: "restarting", data: ["reason": "restarting"])) : nil
        }
        chat.process.restart()
        chat.process.appendReply(sequence: 2)
        chat.gateway.dropAll()
        let shown = try #require(await waitForTimeline(chat.session, timeout: deadline, hasReply))
        #expect(rowTexts(shown).filter { $0 == "reply" }.count == 1)
        let live = await isLive(chat.session, .live(lastSequence: 2, replayEpoch: "e2"))
        #expect(live)
        #expect(!chat.notices.contains { $0.contains("reply") })
        await chat.finish()
    }

    @Test func framesQueuedBehindAPendingResyncAreAppliedAfterIt() async throws {
        let chat = try await openChat(watchdog: quietWatchdog)
        chat.process.restart()
        chat.process.setSequence(2)
        chat.gateway.push(chat.process.frame("message.start", seq: 2, payload: ["turn_id": "t1"]))
        chat.gateway.push(chat.process.frame("message.start", seq: 3, payload: ["turn_id": "t2"]))
        chat.gateway.push(chat.process.frame(
            "message.delta", seq: 4, payload: ["text": "partial", "turn_id": "t2", "segment": 0, "offset": 0]
        ))
        _ = try #require(await waitForTimeline(chat.session, timeout: deadline) { $0.isRunning })
        await chat.finish()
    }

    @Test func aSubscriptionThatSilentlyStoppedDeliveringIsReattachedByTheWatchdog() async throws {
        let chat = try await openChat(watchdog: fastWatchdog)
        chat.process.appendReply(sequence: 2)
        let shown = try #require(await waitForTimeline(chat.session, timeout: deadline, hasReply))
        #expect(rowTexts(shown).filter { $0 == "reply" }.count == 1)
        #expect(chat.gateway.connectionCount >= 2)
        #expect(chat.notices.contains { $0.contains("stream watchdog.reconcile gateway-ahead") })
        await chat.finish()
    }

    @Test func aProbeThatGetsNoAnswerReconnects() async throws {
        let chat = try await openChat(watchdog: fastWatchdog)
        chat.process.script.override("session.events.since") { number in number <= 2 ? .silence : nil }
        chat.process.appendReply(sequence: 2)
        let shown = try #require(await waitForTimeline(chat.session, timeout: .seconds(4), hasReply))
        #expect(rowTexts(shown).filter { $0 == "reply" }.count == 1)
        #expect(chat.gateway.connectionCount >= 2)
        #expect(chat.notices.contains { $0.contains("stream watchdog.reconcile unreachable") })
        await chat.finish()
    }

    @Test func aHealthyStreamIsProbedSparinglyAndNeverReconnected() async throws {
        let chat = try await openChat(watchdog: fastWatchdog)
        try await Task.sleep(for: .seconds(1))
        let probes = chat.process.script.count("session.events.since")
        #expect(probes >= 1)
        #expect(probes <= 12)
        #expect(chat.gateway.connectionCount == 1)
        #expect(!chat.notices.contains { $0.contains("watchdog.reconcile") })
        await chat.finish()
    }

    @Test func theWatchdogIsQuietInTheBackgroundAndChecksAtOnceWhenTheAppReturns() async throws {
        let chat = try await openChat(watchdog: fastWatchdog)
        await chat.session.setForeground(false)
        chat.process.appendReply(sequence: 2)
        try await Task.sleep(for: .milliseconds(700))
        #expect(chat.gateway.connectionCount == 1)
        #expect(chat.process.script.count("session.events.since") == 0)
        let before = await chat.session.timelineSnapshot
        #expect(!hasReply(before))
        await chat.session.setForeground(true)
        let shown = try #require(await waitForTimeline(chat.session, timeout: deadline, hasReply))
        #expect(rowTexts(shown).filter { $0 == "reply" }.count == 1)
        await chat.finish()
    }

    @Test func theGatewayAnswerIsJudgedAgainstTheCursor() throws {
        let cursor = StreamCursor(replayEpoch: "e1", lastSequence: 5)
        func answer(latest: Int, epoch: String = "e1", snapshot: Bool = false) throws -> EventsSinceResult {
            let json = #"{"events":[],"latest_seq":\#(latest),"replay_epoch":"\#(epoch)","snapshot_required":\#(snapshot)}"#
            return try JSONDecoder().decode(EventsSinceResult.self, from: Data(json.utf8))
        }
        let same = try answer(latest: 5)
        let ahead = try answer(latest: 6)
        let regressed = try answer(latest: 2)
        let restarted = try answer(latest: 5, epoch: "e2")
        let required = try answer(latest: 5, snapshot: true)
        #expect(ChatSession.verdict(same, cursor: cursor) == .current)
        #expect(ChatSession.verdict(ahead, cursor: cursor) == .behind("gateway-ahead"))
        #expect(ChatSession.verdict(regressed, cursor: cursor) == .behind("gateway-regressed"))
        #expect(ChatSession.verdict(restarted, cursor: cursor) == .behind("epoch-changed"))
        #expect(ChatSession.verdict(required, cursor: cursor) == .behind("snapshot-required"))
    }

    @Test func aChatOpenedAfterAnotherWasClosedStillGetsTheOwnersEchoAndTwoLiveReplies() async throws {
        let chat = try await openChat(watchdog: quietWatchdog)
        let first = SnapshotCollector(chat.session.timelineSnapshots)
        _ = try #require(await first.waitFor { !$0.rows.isEmpty })
        await first.stop()
        let reopened = SnapshotCollector(chat.session.timelineSnapshots)
        _ = try await chat.session.submit(ownerEntry("hello chief"), files: [])
        chat.process.appendReply(sequence: 2, id: "u98", text: "first answer")
        chat.gateway.push(chat.process.replyFrame(seq: 2, id: "u98", text: "first answer"))
        chat.process.appendReply(sequence: 3, id: "u99", text: "second answer")
        chat.gateway.push(chat.process.replyFrame(seq: 3, id: "u99", text: "second answer"))
        _ = await reopened.waitFor { rowTexts($0).contains("second answer") }
        let texts = reopened.latest.map { rowTexts($0) } ?? []
        #expect(texts.contains("hello chief"))
        #expect(texts.contains("first answer"))
        #expect(texts.contains("second answer"))
        #expect(!chat.notices.contains { $0.contains("resync.requested") })
        #expect(!chat.notices.contains { $0.contains("subscribe stream-ended") })
        await reopened.stop()
        await chat.finish()
    }

    @Test func everyOpenChatGetsEveryUpdateNotOnlyOneOfThem() async throws {
        let chat = try await openChat(watchdog: quietWatchdog)
        let left = SnapshotCollector(chat.session.timelineSnapshots)
        let right = SnapshotCollector(chat.session.timelineSnapshots)
        chat.process.appendReply(sequence: 2)
        chat.gateway.push(chat.process.replyFrame(seq: 2))
        #expect(await left.waitFor(hasReply) != nil)
        #expect(await right.waitFor(hasReply) != nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(left.versions == right.versions)
        #expect(left.versions.count > 1)
        await left.stop()
        await right.stop()
        await chat.finish()
    }

    @Test func aPhaseListenerStartedAfterAnotherWasCancelledStillSeesTheNextPhase() async throws {
        let chat = try await openChat(watchdog: quietWatchdog)
        let first = Task { for await _ in chat.session.updates {} }
        try await Task.sleep(for: .milliseconds(50))
        first.cancel()
        await first.value
        let second = Task { () -> Bool in
            for await update in chat.session.updates {
                if case .phase(.live(let sequence, _)) = update, sequence == 2 { return true }
            }
            return false
        }
        chat.process.appendReply(sequence: 2)
        chat.gateway.push(chat.process.replyFrame(seq: 2))
        let seen = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await second.value }
            group.addTask { try? await Task.sleep(for: deadline); second.cancel(); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(seen)
        await chat.finish()
    }
}
