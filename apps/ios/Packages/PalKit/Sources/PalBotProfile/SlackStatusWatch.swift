import Foundation

public enum SlackWatchOutcome: Sendable, Equatable {
    case settled(SlackStatus)
    case timedOut(SlackStatus)
    case unreachable
    case cancelled
}

public struct SlackStatusWatch: Sendable {
    public static let interval: Duration = .seconds(2)
    public static let limit: Duration = .seconds(60)

    private let interval: Duration
    private let limit: Duration

    public init(interval: Duration = Self.interval, limit: Duration = Self.limit) {
        self.interval = interval
        self.limit = limit
    }

    public func run<C: Clock>(
        clock: C,
        check: @Sendable () async throws -> SlackStatus,
        onStatus: @MainActor @Sendable (SlackStatus) -> Void
    ) async -> SlackWatchOutcome where C.Duration == Duration {
        let deadline = clock.now.advanced(by: limit)
        var last: SlackStatus?
        var lastCheckFailed = false
        while clock.now < deadline {
            do { try await clock.sleep(for: interval) } catch { return .cancelled }
            if Task.isCancelled { return .cancelled }
            do {
                let status = try await check()
                last = status
                lastCheckFailed = false
                await onStatus(status)
                if status.connection.isSettled { return .settled(status) }
            } catch is CancellationError {
                return .cancelled
            } catch {
                lastCheckFailed = true
            }
        }
        guard let last, !lastCheckFailed else { return .unreachable }
        return .timedOut(last)
    }
}
