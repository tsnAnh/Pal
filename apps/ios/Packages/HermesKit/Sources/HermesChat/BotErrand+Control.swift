import Foundation
import HermesProtocol
import HermesTransport

public enum ErrandAnswer: Sendable, Equatable {
    case answered(ErrandOutcome)
    case nothingToAnswer(waitingOn: PendingPrompt?)
}

public enum StopOutcome: Sendable, Equatable {
    case notRunning
    case stopped
    case stopping
}

public enum SteerOutcome: Sendable, Equatable {
    case steered
    case startedNewTask(ErrandMark)
}

extension BotErrand {
    public static let defaultStopSettle = Duration.seconds(8)

    public func lastReply() async throws -> LastReply? {
        try await ensureLive()
        return await session.state.transcript.lastReply
    }

    public func answer(_ text: String, deadline: Duration) async throws -> ErrandAnswer {
        try await ensureLive()
        let transcript = await session.state.transcript
        let waiting = transcript.pendingPrompts
        guard let prompt = waiting.first(where: { $0.kind == .clarify }) else {
            return .nothingToAnswer(waitingOn: waiting.first)
        }
        let mark = transcript.answerMark(for: prompt)
        let reply = prompt.canonicalAnswer(for: text)
        try await control { try await session.answerClarify(prompt, answer: reply) }
        return .answered(await outcome(within: deadline) { $0.errandOutcome(for: mark) })
    }

    public func pendingApproval() async throws -> PendingPrompt? {
        try await ensureLive()
        return await session.state.transcript.pendingPrompts.first { $0.kind == .approval }
    }

    public func pendingQuestion() async throws -> PendingPrompt? {
        try await ensureLive()
        return await session.state.transcript.pendingPrompts.first { $0.kind == .clarify }
    }

    public func decide(_ decision: ApprovalDecision, on prompt: PendingPrompt) async throws {
        guard let choice = decision.choice(in: prompt) else { throw ErrandError.notAccepted }
        try await ensureLive()
        try await control { try await session.answerApproval(prompt, choice: choice) }
    }

    public func stop(settle: Duration = Self.defaultStopSettle) async throws -> StopOutcome {
        try await ensureLive()
        guard await session.state.transcript.isRunning else { return .notRunning }
        try await control { try await session.interrupt() }
        let idle = await Self.within(settle) { [session] in
            await session.awaitState { !$0.transcript.isRunning }
        }
        return idle == nil ? .stopping : .stopped
    }

    public func steer(_ text: String) async throws -> SteerOutcome {
        try await ensureLive()
        if await session.state.transcript.isRunning {
            let status = try await control { try await session.steer(text) }
            if status == .queued { return .steered }
        }
        return .startedNewTask(try await tell(text))
    }

    private func control<Result>(_ body: () async throws -> Result) async throws -> Result {
        do {
            return try await body()
        } catch is CancellationError {
            throw CancellationError()
        } catch GatewayTransportError.rpc {
            throw ErrandError.notAccepted
        } catch {
            throw ErrandError.unreachable
        }
    }
}
