#if os(macOS)
import Foundation
import PalBotProfile
import PalProtocol
import Synchronization

@testable import Pal

func providerRow(_ id: String, kind: String, state: String = "not_set") -> JSONValue {
    .object(["id": .string(id), "name": .string(id), "kind": .string(kind), "state": .string(state)])
}

func plainProvider(_ id: String, _ kind: ModelProviderKind) -> ModelProvider {
    ModelProvider(id: id, name: id, kind: kind, state: .notSet)
}

final class ProviderListStub: Sendable {
    private struct State {
        var rows: [JSONValue]
        var listFails = false
        var methods: [String] = []
    }

    private let state: Mutex<State>

    init(_ rows: [JSONValue]) {
        state = Mutex(State(rows: rows))
    }

    var methods: [String] { state.withLock { $0.methods } }

    func setRows(_ rows: [JSONValue]) { state.withLock { $0.rows = rows } }

    func failLists() { state.withLock { $0.listFails = true } }

    var gateway: BotsGateway {
        BotsGateway { [self] method, _ in try answer(method) }
    }

    private func answer(_ method: String) throws -> JSONValue {
        let rows = try state.withLock { state -> [JSONValue] in
            state.methods.append(method)
            if method == "model.providers.list", state.listFails { throw URLError(.cannotConnectToHost) }
            return state.rows
        }
        switch method {
        case "model.providers.list": return .object(["providers": .array(rows)])
        case "auth.begin": return .object(["outcome": .string("started"), "request_id": .string("r1")])
        case "model.providers.remove": return .object(["outcome": .string("removed")])
        default: throw URLError(.cannotConnectToHost)
        }
    }
}

final class ScriptedBackend: ProviderTestBackend {
    private struct State {
        var removals: [String] = []
        var removeResult = true
        var holdsPins = false
        var waiting: CheckedContinuation<Void, Never>?
    }

    private let state = Mutex(State())

    var removals: [String] { state.withLock { $0.removals } }

    func failRemovals() { state.withLock { $0.removeResult = false } }

    func holdPins() { state.withLock { $0.holdsPins = true } }

    func releasePins() {
        let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.holdsPins = false
            let waiter = state.waiting
            state.waiting = nil
            return waiter
        }
        waiter?.resume()
    }

    func runTest(_ request: ProviderTestRequest) async -> ProviderTestResult {
        ProviderTestResult(ok: true, provider: request.provider, model: request.model, latencyMilliseconds: 12)
    }

    func saveStaged(provider: String, apiKey: SecretString?, baseURL: String?) async -> String? { nil }

    func pin(_ choice: ModelChoice) async -> String? {
        await withCheckedContinuation { continuation in
            let holds = state.withLock { state -> Bool in
                if state.holdsPins { state.waiting = continuation }
                return state.holdsPins
            }
            if !holds { continuation.resume() }
        }
        return nil
    }

    func remove(provider: String) async -> Bool {
        state.withLock { state in
            state.removals.append(provider)
            return state.removeResult
        }
    }
}

@MainActor
func makeOnboarding(
    _ rows: [JSONValue], stub: ProviderListStub? = nil, backend: (any ProviderTestBackend)? = nil,
    finish: @escaping @MainActor (Bool) -> Void = { _ in }
) async -> ProviderOnboardingModel {
    let gateway = (stub ?? ProviderListStub(rows)).gateway
    let client = ModelProvidersClient(gateway: gateway)
    let models = BotModelClient(gateway: gateway, profile: "default")
    let root = FileManager.default.temporaryDirectory.appending(path: "provider-onboarding-\(UUID().uuidString)", directoryHint: .isDirectory)
    let surfaces = SurfaceCache(store: CacheStore(root: root), account: { "test|me" })
    let providers = ModelProvidersModel(client: client, surfaces: surfaces)
    await providers.load()
    let flow = ProviderTestFlow(backend: backend ?? ModelProvidersBackend(providers: client, models: models))
    return ProviderOnboardingModel(providers: providers, flow: flow, client: client, models: models, finish: finish)
}
#endif
