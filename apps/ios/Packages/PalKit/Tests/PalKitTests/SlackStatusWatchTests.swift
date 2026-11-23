import Foundation
import PalBotProfile
import Synchronization
import Testing

private final class FakeClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration

        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private let elapsed = Mutex(Duration.zero)

    var now: Instant { Instant(offset: elapsed.withLock { $0 }) }
    var minimumResolution: Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try Task.checkCancellation()
        elapsed.withLock { $0 = max($0, deadline.offset) }
    }
}

private final class Script: Sendable {
    private let replies: Mutex<[Result<SlackStatus, any Error>]>
    private let fallback: Result<SlackStatus, any Error>
    private let counted = Mutex(0)
    private let seen = Mutex<[SlackStatus]>([])

    init(_ replies: [Result<SlackStatus, any Error>], then fallback: Result<SlackStatus, any Error>) {
        self.replies = Mutex(replies)
        self.fallback = fallback
    }

    var calls: Int { counted.withLock { $0 } }
    var shown: [SlackStatus] { seen.withLock { $0 } }

    func next() async throws -> SlackStatus {
        counted.withLock { $0 += 1 }
        let reply = replies.withLock { $0.isEmpty ? fallback : $0.removeFirst() }
        return try reply.get()
    }

    func record(_ status: SlackStatus) { seen.withLock { $0.append(status) } }
}

private struct Down: Error {}

private let starting = SlackStatus(connection: .starting, state: "pending_restart")
private let connected = SlackStatus(connection: .connected, state: "connected")
private let failed = SlackStatus(connection: .failed, detail: "Pal couldn't start Slack for this bot. Try again, or update the tokens.")

@Suite("Slack status watch")
struct SlackStatusWatchTests {
    private func run(_ script: Script, clock: FakeClock = FakeClock()) async -> SlackWatchOutcome {
        await SlackStatusWatch().run(clock: clock, check: { try await script.next() }, onStatus: { script.record($0) })
    }

    @Test("loading to success: settles on the first connected status and reports each status")
    func success() async {
        let script = Script([.success(starting), .success(starting)], then: .success(connected))
        #expect(await run(script) == .settled(connected))
        #expect(script.calls == 3)
        #expect(script.shown == [starting, starting, connected])
    }

    @Test("loading to error: a failed status settles the wait")
    func failure() async {
        #expect(await run(Script([.success(starting)], then: .success(failed))) == .settled(failed))
    }

    @Test("loading to timeout: stops at the 60 second bound with the last status")
    func timeout() async {
        let clock = FakeClock()
        let script = Script([], then: .success(starting))
        #expect(await run(script, clock: clock) == .timedOut(starting))
        #expect(script.calls == 30)
        #expect(clock.now.offset == SlackStatusWatch.limit)
    }

    @Test("a failing poll is retried and does not hide a later answer")
    func failingPollRecovers() async {
        let script = Script([.failure(Down()), .failure(Down())], then: .success(connected))
        #expect(await run(script) == .settled(connected))
        #expect(script.calls == 3)
    }

    @Test("polls that keep failing end as unreachable, not as a silent stall")
    func alwaysFailing() async {
        let script = Script([], then: .failure(Down()))
        #expect(await run(script) == .unreachable)
        #expect(script.calls == 30)
        #expect(await run(Script([.success(starting)], then: .failure(Down()))) == .unreachable)
    }

    @Test("a cancelled screen stops the wait")
    func cancelled() async {
        let script = Script([], then: .success(starting))
        let watch = Task { await run(script) }
        watch.cancel()
        #expect(await watch.value == .cancelled)
    }

    @Test("retry after a timeout starts a fresh bounded wait and settles")
    func retryAfterTimeout() async {
        #expect(await run(Script([], then: .success(starting))) == .timedOut(starting))
        #expect(await run(Script([.success(starting)], then: .success(connected))) == .settled(connected))
    }
}
