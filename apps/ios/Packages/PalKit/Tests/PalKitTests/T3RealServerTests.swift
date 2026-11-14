import Foundation
import PalAuth
@testable import PalConnect
import PalDevice
import PalProtocol
import PalREST
import PalT3Code
import Synchronization
import Testing

private enum RealT3 {
    static let baseDirectory = ProcessInfo.processInfo.environment["PAL_T3_E2E_BASE_DIR"]
    static let pairingCode = ProcessInfo.processInfo.environment["PAL_T3_E2E_PAIRING_CODE"]
    static var enabled: Bool { baseDirectory != nil && pairingCode != nil }
}

private struct ApprovingBrowser: AuthorizationBrowser {
    let origin: URL
    let pairingCode: String

    func present(_ url: URL) async throws {
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let wanted = ["response_type", "client_id", "redirect_uri", "code_challenge", "code_challenge_method", "state", "resource"]
        var authorization: [String: String] = [:]
        for item in components.queryItems ?? [] where wanted.contains(item.name) { authorization[item.name] = item.value }
        let body: [String: Any] = [
            "authorization": authorization,
            "decision": ["_tag": "pairing-code", "access": "approval-required", "code": pairingCode],
        ]
        var request = URLRequest(url: origin.appending(path: "oauth/mcp/decision"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let redirect = try #require(((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["redirectTo"] as? String)
        let callback = try #require(URL(string: redirect))
        #expect(callback.host() == "127.0.0.1")
        _ = try? await URLSession.shared.data(from: callback)
        try await Task.sleep(for: .seconds(60))
    }

    func dismiss() async {}
}

private final class AcceptingRegistrar: T3Registering {
    let registered = Mutex(0)

    func register() async throws { registered.withLock { $0 += 1 } }
    func unregister() async {}
}

@MainActor
@Suite("Real T3 Code server", .enabled(if: RealT3.enabled), .serialized)
struct T3RealServerTests {
    @Test func signsInOverOAuthAndListsToolsThroughTheBridgeThenClosesCleanly() async throws {
        let base = URL(fileURLWithPath: try #require(RealT3.baseDirectory), isDirectory: true)
        let locator = T3Locator.standard(baseDirectory: base)
        let runtime = try #require(locator.runtime())
        #expect(runtime.origin.host() == "127.0.0.1")

        let tokens = InMemoryT3TokenStore()
        let registrar = AcceptingRegistrar()
        let controller = T3CodeController(
            locator: locator, tokens: tokens,
            authorizer: T3OAuthAuthorizer(
                browser: ApprovingBrowser(origin: runtime.origin, pairingCode: try #require(RealT3.pairingCode)),
                callbackTimeout: .seconds(45)
            ),
            registrar: registrar
        )
        await controller.refresh()
        #expect(controller.connection == .signedOut)
        await controller.connect()
        #expect(controller.connection == .connected)
        #expect(registrar.registered.withLock { $0 } == 1)
        let token = try #require(try tokens.load())
        #expect(token.expiresAt != nil)

        let recorder = RelayRecorder()
        let bridge = T3McpBridge(locator: locator, tokens: tokens)
        func frame(_ message: JSONValue) -> DeviceMcpFrame { DeviceMcpFrame(relayID: "e2e-relay", server: .t3code, message: message) }
        await bridge.relay(frame([
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "pal-e2e", "version": "1"]],
        ]), over: recorder.channel)
        #expect(await awaitCondition { recorder.ids("e2e-relay") == [1] })
        #expect(recorder.deliveries[0].message["result"]?["serverInfo"] != nil)
        await bridge.relay(frame(["jsonrpc": "2.0", "method": "notifications/initialized"]), over: recorder.channel)
        await bridge.relay(frame(["jsonrpc": "2.0", "id": 2, "method": "tools/list"]), over: recorder.channel)
        #expect(await awaitCondition { recorder.ids("e2e-relay") == [1, 2] })
        let tools = try #require(recorder.deliveries[1].message["result"]?["tools"]?.arrayValue)
        let names = tools.compactMap { $0["name"]?.stringValue }
        print("T3 tools via bridge: \(names)")
        #expect(!names.isEmpty)
        #expect(recorder.failures.isEmpty)

        await bridge.close(DeviceMcpClose(relayID: "e2e-relay", reason: .clientClosed))
        #expect(await bridge.openRelayCount == 0)

        let stale = InMemoryT3TokenStore(T3Token(access: SecretString("not-a-real-token"), expiresAt: nil))
        let staleRecorder = RelayRecorder()
        let staleBridge = T3McpBridge(locator: locator, tokens: stale)
        await staleBridge.relay(DeviceMcpFrame(relayID: "stale", server: .t3code, message: ["jsonrpc": "2.0", "id": 1, "method": "initialize"]), over: staleRecorder.channel)
        #expect(await awaitCondition { staleRecorder.failures.count == 1 })
        #expect(staleRecorder.failures[0].code == .authRequired)
    }
}
