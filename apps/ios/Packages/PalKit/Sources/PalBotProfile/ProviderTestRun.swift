import Foundation

struct ProviderTestRun: Sendable {
    enum Step: Sendable {
        case slow
        case deadline
        case finished(ProviderTestResult)
    }

    let steps: AsyncStream<Step>
    private let continuation: AsyncStream<Step>.Continuation
    private let tasks: [Task<Void, Never>]

    init(
        backend: any ProviderTestBackend, request: ProviderTestRequest, sleep: @escaping @Sendable (Duration) async throws -> Void,
        slowAfter: Duration, giveUpAfter: Duration
    ) {
        let (steps, continuation) = AsyncStream<Step>.makeStream()
        self.steps = steps
        self.continuation = continuation
        tasks = [
            Task {
                guard !Task.isCancelled else { return }
                let result = await backend.runTest(request)
                continuation.yield(.finished(result))
            },
            Task { await ProviderTestRun.signal(.slow, after: slowAfter, sleep: sleep, into: continuation) },
            Task { await ProviderTestRun.signal(.deadline, after: giveUpAfter, sleep: sleep, into: continuation) },
        ]
    }

    func stop() {
        tasks.forEach { $0.cancel() }
        continuation.finish()
    }

    private static func signal(
        _ step: Step, after delay: Duration, sleep: @Sendable (Duration) async throws -> Void, into continuation: AsyncStream<Step>.Continuation
    ) async {
        do {
            try await sleep(delay)
        } catch {
            return
        }
        guard !Task.isCancelled else { return }
        continuation.yield(step)
    }
}
