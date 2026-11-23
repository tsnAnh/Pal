import Foundation
import PalBotProfile
import PalProtocol
import Synchronization

let flowSecret = "sk-fake-\(UUID().uuidString)"

func flowProvider(_ id: String = "openrouter", kind: ModelProviderKind = .apiKey, state: ModelProviderState = .notSet) -> ModelProvider {
    ModelProvider(id: id, name: id.capitalized, kind: kind, state: state)
}

func flowPass(model: String = "gpt-5", latency: Int = 412, preview: String? = "Hi.") -> ProviderTestResult {
    ProviderTestResult(ok: true, provider: "any", model: model, latencyMilliseconds: latency, replyPreview: preview)
}

func flowFailure(_ kind: ProviderTestFailureKind, _ reason: String = "That didn't work.") -> ProviderTestResult {
    ProviderTestResult(
        ok: false, provider: "any", model: "gpt-5", latencyMilliseconds: 0,
        error: ProviderTestError(code: "x", reason: reason, retryable: true, kind: kind))
}

let flowCodex = flowProvider("openai-codex", kind: .deviceCode, state: .set)

@MainActor
func makeTestFlow(_ backend: FakeProviderBackend, _ sleeper: ManualSleeper) -> ProviderTestFlow {
    ProviderTestFlow(backend: backend, sleep: { try await sleeper.sleep($0) })
}

@MainActor
func flowStaged(_ flow: ProviderTestFlow, key: String? = flowSecret, address: String? = nil, model: String = "gpt-5") {
    flow.start(provider: flowProvider(), credential: .staged(apiKey: key.map(SecretString.init), baseURL: address), ownsCredential: false)
    flow.select(model: model)
}

@MainActor
func flowWritten(_ flow: ProviderTestFlow, owns: Bool = true, model: String = "gpt-5") {
    flow.start(provider: flowCodex, credential: .written, ownsCredential: owns)
    flow.select(model: model)
}

@MainActor
func flowSettled(_ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<100_000 {
        if condition() { return true }
        await Task.yield()
    }
    return condition()
}

final class ResultGate: Sendable {
    private struct Slot {
        var result: ProviderTestResult?
        var waiter: CheckedContinuation<ProviderTestResult, Never>?
    }

    private let slot = Mutex(Slot())

    func wait() async -> ProviderTestResult {
        await withCheckedContinuation { continuation in
            let ready: ProviderTestResult? = slot.withLock { slot in
                if let result = slot.result { return result }
                slot.waiter = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }

    func open(_ result: ProviderTestResult) {
        let waiter = slot.withLock { slot -> CheckedContinuation<ProviderTestResult, Never>? in
            slot.result = result
            let waiter = slot.waiter
            slot.waiter = nil
            return waiter
        }
        waiter?.resume(returning: result)
    }
}

final class ManualSleeper: Sendable {
    private struct Waiter {
        let duration: Duration
        let continuation: CheckedContinuation<Void, any Error>
    }

    private enum Action {
        case resume
        case cancel
        case wait
    }

    private struct State {
        var released: Set<Duration> = []
        var cancelled: Set<Int> = []
        var waiters: [Int: Waiter] = [:]
        var next = 0
    }

    private let state = Mutex(State())

    func sleep(_ duration: Duration) async throws {
        let id = state.withLock { state -> Int in
            state.next += 1
            return state.next
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let action = state.withLock { state -> Action in
                    if state.cancelled.contains(id) { return .cancel }
                    if state.released.contains(duration) { return .resume }
                    state.waiters[id] = Waiter(duration: duration, continuation: continuation)
                    return .wait
                }
                switch action {
                case .resume: continuation.resume()
                case .cancel: continuation.resume(throwing: CancellationError())
                case .wait: break
                }
            }
        } onCancel: {
            let waiter = state.withLock { state -> Waiter? in
                state.cancelled.insert(id)
                return state.waiters.removeValue(forKey: id)
            }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    func release(_ duration: Duration) {
        let ready = state.withLock { state -> [Waiter] in
            state.released.insert(duration)
            let ids = state.waiters.filter { $0.value.duration == duration }.map(\.key)
            return ids.compactMap { state.waiters.removeValue(forKey: $0) }
        }
        ready.forEach { $0.continuation.resume() }
    }
}

final class FakeProviderBackend: ProviderTestBackend {
    enum Script: Sendable {
        case result(ProviderTestResult)
        case gate(ResultGate)
    }

    struct Save: Sendable, Equatable {
        let provider: String
        let apiKey: SecretString?
        let baseURL: String?
    }

    private struct Record {
        var tests: [ProviderTestRequest] = []
        var saves: [Save] = []
        var pins: [ModelChoice] = []
        var removals: [String] = []
        var scripts: [Script] = []
        var saveReplies: [String?] = []
        var pinReplies: [String?] = []
        var removeReplies: [Bool] = []
    }

    private let record = Mutex(Record())

    var tests: [ProviderTestRequest] { record.withLock { $0.tests } }
    var saves: [Save] { record.withLock { $0.saves } }
    var pins: [ModelChoice] { record.withLock { $0.pins } }
    var removals: [String] { record.withLock { $0.removals } }

    func script(_ scripts: Script...) { record.withLock { $0.scripts.append(contentsOf: scripts) } }
    func script(_ results: ProviderTestResult...) { record.withLock { $0.scripts.append(contentsOf: results.map(Script.result)) } }
    func replySave(_ replies: String?...) { record.withLock { $0.saveReplies.append(contentsOf: replies) } }
    func replyPin(_ replies: String?...) { record.withLock { $0.pinReplies.append(contentsOf: replies) } }
    func replyRemove(_ replies: Bool...) { record.withLock { $0.removeReplies.append(contentsOf: replies) } }

    func runTest(_ request: ProviderTestRequest) async -> ProviderTestResult {
        let script = record.withLock { record -> Script in
            record.tests.append(request)
            return record.scripts.isEmpty ? .result(flowPass()) : record.scripts.removeFirst()
        }
        switch script {
        case .result(let result): return result
        case .gate(let gate): return await gate.wait()
        }
    }

    func saveStaged(provider: String, apiKey: SecretString?, baseURL: String?) async -> String? {
        record.withLock { record in
            record.saves.append(Save(provider: provider, apiKey: apiKey, baseURL: baseURL))
            return record.saveReplies.isEmpty ? nil : record.saveReplies.removeFirst()
        }
    }

    func pin(_ choice: ModelChoice) async -> String? {
        record.withLock { record in
            record.pins.append(choice)
            return record.pinReplies.isEmpty ? nil : record.pinReplies.removeFirst()
        }
    }

    func remove(provider: String) async -> Bool {
        record.withLock { record in
            record.removals.append(provider)
            return record.removeReplies.isEmpty ? true : record.removeReplies.removeFirst()
        }
    }
}
