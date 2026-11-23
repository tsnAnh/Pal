#if os(macOS)
import Foundation
import PalAuth
import PalClient
import PalDiagnostics
import PalLocalEngine
import PalProtocol
import PalREST
import PalRoster
import Synchronization
import Testing

@testable import Pal

private struct OfflineTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> HTTPResult { throw URLError(.cannotConnectToHost) }
}

private struct EngineProbeStub: EngineProbing {
    func probe(port: Int, token: LocalToken?) async -> EngineProbeResult { .unreachable }
}

private final class SlowRunner: EngineProcessRunning {
    let enableCalls = Mutex(0)
    let body: String
    let code: Int

    init(body: String, code: Int = 0) {
        self.body = body
        self.code = code
    }

    func run(_ command: EngineCommand, onLine: @escaping @Sendable (EngineOutputLine) -> Void) async -> EngineProcessOutcome {
        if command.arguments.contains("on") { enableCalls.withLock { $0 += 1 } }
        try? await Task.sleep(for: .milliseconds(150))
        onLine(EngineOutputLine(isError: false, text: body))
        return .exited(code: code)
    }
}

private let onBody = "{\"enabled\":true,\"url\":\"http://100.64.0.7:9120\",\"username\":\"pal\",\"password\":\"pw-canary\",\"reachable\":true}"
private let offBody = "{\"enabled\":false,\"url\":null,\"username\":null,\"reachable\":null}"

@MainActor
private func makeModel(runner: SlowRunner) throws -> LocalEngineModel {
    let root = FileManager.default.temporaryDirectory.appending(path: "tailnet-model-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    let identity = DeviceIdentity(deviceID: "0B7F3F2E-5A4B-4E5E-9D1C-1F2E3D4C5B6A", formFactor: .phone, appVersion: "0.1.0 (1)")
    let transport = OfflineTransport()
    let connection = ConnectionModel(
        auth: try AuthSession(store: InMemoryCredentialStore(), transport: transport),
        transport: transport,
        diagnostics: .silent,
        initialBaseURL: "http://tailnet-model-tests.invalid",
        presence: ReachPresence(identity: identity),
        cache: CacheStore(root: root)
    )
    let service = LocalEngineService(
        configuration: LocalEngineConfiguration(
            hermesHome: root.appending(path: "home", directoryHint: .isDirectory), userHome: root, preferredPort: 9300
        ),
        installer: nil, runner: runner, probe: EngineProbeStub(), makeTrace: { "trace0000001" }
    )
    return LocalEngineModel(connection: connection, diagnostics: .silent, service: service)
}

@MainActor
@Suite("Local engine tailnet model", .serialized)
struct LocalEngineTailnetModelTests {
    @Test func aSecondEnableWhileOneRunsIsBlocked() async throws {
        let runner = SlowRunner(body: onBody)
        let model = try makeModel(runner: runner)
        let first = Task { await model.enableTailnet() }
        try await Task.sleep(for: .milliseconds(40))
        #expect(model.isUpdatingTailnet)
        await model.enableTailnet()
        await first.value
        #expect(runner.enableCalls.withLock { $0 } == 1)
        #expect(model.tailnet == .on(url: "http://100.64.0.7:9120", username: "pal", reachable: true))
        #expect(!model.isUpdatingTailnet)
    }

    @Test func dismissingClearsThePasswordButKeepsTheAddress() async throws {
        let model = try makeModel(runner: SlowRunner(body: onBody))
        await model.enableTailnet()
        #expect(model.tailnetPassword == "pw-canary")
        model.dismissTailnetPassword()
        #expect(model.tailnetPassword == nil)
        #expect(model.tailnet != .off)
    }

    @Test func turningOffClearsThePassword() async throws {
        let on = try makeModel(runner: SlowRunner(body: onBody))
        await on.enableTailnet()
        #expect(on.tailnetPassword != nil)
        let off = try makeModel(runner: SlowRunner(body: offBody))
        await off.disableTailnet()
        #expect(off.tailnet == .off && off.tailnetPassword == nil)
    }

    @Test func aFailureShowsTheMessageAsIs() async throws {
        let model = try makeModel(runner: SlowRunner(body: "{\"error\": \"Tailscale isn't running on this Mac.\"}", code: 1))
        await model.enableTailnet()
        #expect(model.tailnetFailure == "Tailscale isn't running on this Mac.")
        #expect(model.tailnetPassword == nil)
    }
}
#endif
