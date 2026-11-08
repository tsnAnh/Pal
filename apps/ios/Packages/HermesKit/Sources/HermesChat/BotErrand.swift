import Foundation

public enum ErrandError: Error, Sendable, Equatable {
    case unreachable
    case signInRequired
    case notSaved
    case refused(reason: String)
    case notAccepted
}

public struct BotErrand: Sendable {
    public static let defaultConnectTimeout = Duration.seconds(10)

    let botID: String
    let session: ChatSession
    let outbox: Outbox
    private let connectTimeout: Duration

    public init(botID: String, session: ChatSession, outbox: Outbox, connectTimeout: Duration = Self.defaultConnectTimeout) {
        self.botID = botID
        self.session = session
        self.outbox = outbox
        self.connectTimeout = connectTimeout
    }

    public func tell(_ text: String, files: [OutgoingFile] = []) async throws -> ErrandMark {
        try await ensureLive()
        let before = await session.state.transcript.userItemCount
        let entry: OutboxEntry
        do {
            entry = try await outbox.enqueue(botID: botID, text: text, files: files)
        } catch {
            throw ErrandError.notSaved
        }
        try await deliver(entry)
        return ErrandMark(submissionID: entry.submissionID, text: text, userItemsBefore: before)
    }

    public func ask(_ text: String, deadline: Duration) async throws -> ErrandOutcome {
        try await ensureLive()
        if let waiting = await session.state.transcript.pendingPrompts.first { return .needsInput(waiting) }
        let mark = try await tell(text)
        return await outcome(within: deadline) { $0.errandOutcome(for: mark) }
    }

    func outcome(
        within deadline: Duration,
        _ reduce: @escaping @Sendable (Transcript) -> ErrandOutcome?
    ) async -> ErrandOutcome {
        let settled = await Self.within(deadline) { [session] in
            await session.awaitState { reduce($0.transcript) != nil }
        }
        return settled.flatMap { reduce($0.transcript) } ?? .stillWorking
    }

    func ensureLive() async throws {
        do {
            try await session.start()
        } catch {
            throw await session.terminalFailure == nil ? ErrandError.unreachable : ErrandError.signInRequired
        }
        let live = await Self.within(connectTimeout) { [session] in
            await session.awaitState { state in
                if case .live = state.phase { true } else { false }
            }
        }
        guard live != nil else { throw ErrandError.unreachable }
    }

    private func deliver(_ entry: OutboxEntry) async throws {
        switch await outbox.deliver(entry.submissionID) {
        case .admitted:
            return
        case .failed(let reason):
            throw ErrandError.refused(reason: reason)
        case .retryLater:
            try? await outbox.cancel(entry.submissionID)
            throw ErrandError.unreachable
        case .alreadyDone, .inFlight, .unknownEntry:
            try await awaitPeerDelivery(of: entry)
        }
    }

    private func awaitPeerDelivery(of entry: OutboxEntry) async throws {
        for _ in 0..<30 {
            let stored = await outbox.snapshot(botID: botID).first { $0.submissionID == entry.submissionID }
            switch stored?.state {
            case .admitted: return
            case .failed(let reason): throw ErrandError.refused(reason: reason)
            case .pending, nil: try? await Task.sleep(for: .milliseconds(100))
            }
        }
        try? await outbox.cancel(entry.submissionID)
        throw ErrandError.unreachable
    }

    static func within<Value: Sendable>(
        _ limit: Duration,
        _ operation: @escaping @Sendable () async -> Value?
    ) async -> Value? {
        await withTaskGroup(of: Value?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(for: limit)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
