import Foundation
import PalAuth
@testable import PalConnect
import PalProtocol
import PalREST
import PalTransport
import Synchronization
import Testing

private func disconnectedUpwork() -> ConnectApp {
    deviceSignInApp()
}

@Suite("Upwork connect through the service")
struct UpworkServiceConnectTests {
    @Test func withoutTheNativeFlowItIsUnavailableAndTouchesNothing() async {
        let rpc = GatewayRPC()
        let service = ConnectAppsService(rpc: rpc, profile: nil)
        await #expect(throws: ConnectAppsError.unavailable) { try await service.connect(disconnectedUpwork()) }
        #expect(rpc.methods.isEmpty)
    }

    @Test func addsThePresetThenSubmitsTheTokens() async throws {
        let rpc = GatewayRPC()
        let native = McpNativeSignIn(flow: oauthFlow(FakeAuthServer(), CallbackBrowser()), rpc: rpc)
        let service = ConnectAppsService(rpc: rpc, profile: nil, browser: UnavailableAuthorizationBrowser(), nativeSignIn: native)
        try await service.connect(disconnectedUpwork())
        #expect(rpc.methods == ["mcp.servers.add", "auth.submit_oauth_tokens"])
    }

    @Test func aRefusedSignInRemovesThePresetItJustAdded() async {
        let rpc = GatewayRPC(reply: ["ok": false, "reason": "Not approved."])
        let native = McpNativeSignIn(flow: oauthFlow(FakeAuthServer(), CallbackBrowser()), rpc: rpc)
        let service = ConnectAppsService(rpc: rpc, profile: nil, browser: UnavailableAuthorizationBrowser(), nativeSignIn: native)
        await #expect(throws: ConnectAppsError.signInFailed("Not approved.")) { try await service.connect(disconnectedUpwork()) }
        #expect(rpc.methods == ["mcp.servers.add", "auth.submit_oauth_tokens", "mcp.servers.remove"])
    }

    @Test func aTimedOutSignInRollsBackAndSaysWhy() async {
        let rpc = GatewayRPC()
        let native = McpNativeSignIn(flow: oauthFlow(FakeAuthServer(), CallbackBrowser(.neverCalls), timeout: .milliseconds(200)), rpc: rpc)
        let service = ConnectAppsService(rpc: rpc, profile: nil, browser: UnavailableAuthorizationBrowser(), nativeSignIn: native)
        await #expect(throws: ConnectAppsError.signInFailed(McpOAuthError.timedOut.reason)) { try await service.connect(disconnectedUpwork()) }
        #expect(rpc.methods == ["mcp.servers.add", "mcp.servers.remove"])
    }
}

private final class RefusingBrowser: AuthorizationBrowser {
    func present(_ url: URL) async throws { throw SignInError.browserUnavailable }
    func dismiss() async {}
}

private final class FailingAddRPC: ConnectRPC {
    private let log = Mutex<[String]>([])
    let addError: any Error

    init(addError: any Error) { self.addError = addError }

    var methods: [String] { log.withLock { $0 } }

    func call(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        log.withLock { $0.append(method) }
        if method == "mcp.servers.add" { throw addError }
        return ["ok": true]
    }
}

@Suite("Upwork connect failures stay visible")
struct UpworkSilentFailureTests {
    private func service(_ rpc: FailingAddRPC, browser: any AuthorizationBrowser = CallbackBrowser()) -> ConnectAppsService {
        let native = McpNativeSignIn(flow: McpOAuthFlow(
                resource: UpworkConnector.serverURL, transport: FakeAuthServer(), browser: browser, callbackTimeout: .seconds(20)
            ), rpc: rpc)
        return ConnectAppsService(rpc: rpc, profile: nil, browser: UnavailableAuthorizationBrowser(), nativeSignIn: native)
    }

    @Test func aRefusedServerAddShowsTheGatewaysMessage() async {
        let rpc = FailingAddRPC(addError: GatewayTransportError.rpc(RPCError(code: 4001, message: "Unknown preset upwork")))
        let reason = McpOAuthError.serverAddFailed("Unknown preset upwork").reason
        await #expect(throws: ConnectAppsError.signInFailed(reason)) { try await service(rpc).connect(disconnectedUpwork()) }
        #expect(rpc.methods == ["mcp.servers.add"])
    }

    @Test func aServerAddThatCannotReachTheGatewaySaysSo() async {
        let rpc = FailingAddRPC(addError: GatewayTransportError.timedOut)
        await #expect(throws: ConnectAppsError.signInFailed(McpOAuthError.gatewayUnavailable.reason)) {
            try await service(rpc).connect(disconnectedUpwork())
        }
    }

    @Test func aServerThatIsAlreadyThereSignsInAndIsNeverRemoved() async {
        let rpc = FailingAddRPC(addError: GatewayTransportError.rpc(RPCError(code: 4090, message: "exists")))
        await #expect(throws: ConnectAppsError.signInFailed(McpOAuthError.timedOut.reason)) {
            let native = McpNativeSignIn(
                flow: McpOAuthFlow(
                resource: UpworkConnector.serverURL, transport: FakeAuthServer(), browser: CallbackBrowser(.neverCalls), callbackTimeout: .milliseconds(200)
            ),
                rpc: rpc
            )
            try await ConnectAppsService(rpc: rpc, profile: nil, browser: UnavailableAuthorizationBrowser(), nativeSignIn: native).connect(disconnectedUpwork())
        }
        #expect(rpc.methods == ["mcp.servers.add"])
    }

    @Test func aBrowserThatCannotOpenIsTypedAndRollsBack() async {
        let working = GatewayRPC()
        let refusing = McpNativeSignIn(
            flow: McpOAuthFlow(resource: UpworkConnector.serverURL, transport: FakeAuthServer(), browser: RefusingBrowser(), callbackTimeout: .seconds(20)),
            rpc: working
        )
        let service = ConnectAppsService(rpc: working, profile: nil, browser: UnavailableAuthorizationBrowser(), nativeSignIn: refusing)
        await #expect(throws: ConnectAppsError.signInFailed(McpOAuthError.browserUnavailable.reason)) { try await service.connect(disconnectedUpwork()) }
        #expect(working.methods == ["mcp.servers.add", "mcp.servers.remove"])
    }
}
