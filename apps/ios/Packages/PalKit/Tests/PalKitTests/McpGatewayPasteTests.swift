import Foundation
import PalConnect
import PalProtocol
import Testing

private let authURL = "https://auth.example.com/authorize?response_type=code&state=st-1&redirect_uri=http%3A%2F%2F127.0.0.1%3A50123%2Fcallback"
private let redirect = "http://127.0.0.1:50123/callback"

private func preset(state: ConnectAppState = .disconnected) -> ConnectApp {
    ConnectApp(
        id: "mcp:notion", name: "Notion", summary: "", category: "Other", iconURL: nil,
        source: .mcp(name: "notion", requires: []), state: state
    )
}

private func gateway(poll: JSONValue = ["status": "approved"], callback: JSONValue = ["ok": true], url: String = authURL) -> CustomRPC {
    CustomRPC([
        "mcp.servers.add": { _ in ["ok": true] },
        "mcp.servers.remove": { _ in ["ok": true] },
        "mcp.servers.oauth.start": { _ in ["session_id": "s1", "auth_url": .string(url)] },
        "mcp.servers.oauth.callback": { _ in callback },
        "mcp.servers.oauth.poll": { _ in poll },
        "mcp.servers.oauth.cancel": { _ in ["ok": true] },
    ])
}

@Suite("Other connector sign-in route")
struct McpConnectRouteTests {
    @Test func theRouteFollowsTheConnectorKindAndPlatform() {
        #expect(McpConnectRoute.decide(requires: ["API_KEY"], platform: .iPhone) == .apiKey)
        #expect(McpConnectRoute.decide(requires: ["API_KEY"], platform: .mac) == .apiKey)
        #expect(McpConnectRoute.decide(requires: [], platform: .iPhone) == .pasteAddress)
        #expect(McpConnectRoute.decide(requires: [], platform: .iPad) == .pasteAddress)
        #expect(McpConnectRoute.decide(requires: [], platform: .mac) == .loopback)
    }
}

@Suite("Other connector failures")
struct McpSignInFailureTests {
    @Test func providerRefusalsMapToPlainTypedFailures() {
        #expect(McpSignInFailure.classify("Dynamic client registration failed") == .registrationRejected)
        #expect(McpSignInFailure.classify("invalid_client") == .registrationRejected)
        #expect(McpSignInFailure.classify("redirect_uri mismatch") == .redirectRefused)
        #expect(McpSignInFailure.classify("access_denied") == .denied)
        #expect(McpSignInFailure.classify("invalid_grant") == .expired)
        #expect(McpSignInFailure.classify("OAuth state expired") == .expired)
        #expect(McpSignInFailure.classify("unsupported_grant_type") == .unsupportedGrant)
        #expect(McpSignInFailure.classify("boom 500") == .other)
        #expect(McpSignInFailure.classify(nil) == .other)
    }

    @Test func everyReasonIsPlainWords() {
        for failure in McpSignInFailure.allCases {
            let text = failure.reason
            #expect(!text.isEmpty)
            for banned in ["oauth", "redirect_uri", "invalid_", "http", "pkce", "RPC"] {
                #expect(!text.localizedCaseInsensitiveContains(banned))
            }
        }
    }
}

@Suite("Other connector paste sign-in")
struct McpGatewayPasteSessionTests {
    @Test func aValidAddressIsRelayedOnceAndTheRowConnects() async throws {
        let rpc = gateway()
        let session = try await customService(rpc).beginMcpPaste(preset())
        #expect(session.authorizeURL.absoluteString == authURL)
        let start = try #require(rpc.params("mcp.servers.oauth.start").first)
        #expect(start["client_redirect_uri"]?.stringValue?.hasPrefix("http://127.0.0.1:") == true)
        let outcome = await session.submit("\(redirect)?code=abc&state=st-1")
        #expect(outcome == .signedIn)
        let relayed = try #require(rpc.params("mcp.servers.oauth.callback").first)
        #expect(relayed["code"]?.stringValue == "abc")
        #expect(relayed["state"]?.stringValue == "st-1")
        let again = await session.submit("\(redirect)?code=abc&state=st-1")
        #expect(again == .failed(McpOAuthError.handshakeUsed.reason))
        #expect(rpc.params("mcp.servers.oauth.callback").count == 1)
    }

    @Test(arguments: [
        "code=abc&state=st-1",
        "?code=abc&state=st-1",
        "http://127.0.0.1:50123/callback?code=abc&state=st-1",
    ])
    func everyAcceptedShapeCompletes(_ pasted: String) async throws {
        let rpc = gateway()
        let session = try await customService(rpc).beginMcpPaste(preset())
        let outcome = await session.submit(pasted)
        #expect(outcome == .signedIn)
    }

    @Test(arguments: [
        "http://evil.example.com/callback?code=abc&state=st-1",
        "http://127.0.0.1:9/callback?code=abc&state=st-1",
        "http://127.0.0.1:50123/callback?code=a&code=b&state=st-1",
        "http://127.0.0.1:50123/callback?code=abc",
        "http://127.0.0.1:50123/callback?state=st-1",
        "not an address",
        "abc st-1",
        "",
    ])
    func badShapesKeepTheAttemptOpenAndRelayNothing(_ pasted: String) async throws {
        let rpc = gateway()
        let session = try await customService(rpc).beginMcpPaste(preset())
        let outcome = await session.submit(pasted)
        guard case .tryAgain = outcome else {
            Issue.record("expected tryAgain, got \(outcome)")
            return
        }
        #expect(rpc.params("mcp.servers.oauth.callback").isEmpty)
        #expect(!rpc.methods().contains("mcp.servers.remove"))
    }

    @Test func aWrongStateEndsTheAttemptAndRemovesAFreshlyAddedServer() async throws {
        let rpc = gateway()
        let session = try await customService(rpc).beginMcpPaste(preset())
        let outcome = await session.submit("\(redirect)?code=abc&state=other")
        guard case .failed = outcome else {
            Issue.record("expected failed, got \(outcome)")
            return
        }
        #expect(rpc.params("mcp.servers.oauth.callback").isEmpty)
        #expect(rpc.methods().contains("mcp.servers.oauth.cancel"))
        #expect(rpc.methods().last == "mcp.servers.remove")
    }

    @Test func aDeniedAddressFailsWithPlainWords() async throws {
        let rpc = gateway()
        let session = try await customService(rpc).beginMcpPaste(preset())
        let outcome = await session.submit("\(redirect)?error=access_denied&state=st-1")
        #expect(outcome == .failed("Access was not granted."))
    }

    @Test func aProviderRefusalAfterTheRelayIsTyped() async throws {
        let rpc = gateway(poll: ["status": "error", "error_message": "invalid_grant: code expired"])
        let session = try await customService(rpc).beginMcpPaste(preset())
        let outcome = await session.submit("\(redirect)?code=abc&state=st-1")
        #expect(outcome == .failed(McpSignInFailure.expired.reason))
        #expect(rpc.methods().last == "mcp.servers.remove")
    }

    @Test func aGatewayRefusalOfTheRelayIsTyped() async throws {
        let rpc = gateway(callback: ["ok": false, "error_message": "state mismatch"])
        let session = try await customService(rpc).beginMcpPaste(preset())
        let outcome = await session.submit("\(redirect)?code=abc&state=st-1")
        #expect(outcome == .failed(McpSignInFailure.expired.reason))
    }

    @Test func aReconnectKeepsTheServerWhenItIsCancelled() async throws {
        let rpc = gateway()
        let session = try await customService(rpc).beginMcpPaste(preset(state: .needsAuthorization))
        await session.cancel()
        #expect(rpc.methods().contains("mcp.servers.oauth.cancel"))
        #expect(!rpc.methods().contains("mcp.servers.remove"))
        #expect(!rpc.methods().contains("mcp.servers.add"))
    }

    @Test func startRefusedByTheProviderIsTypedAndRollsBack() async {
        let refusing = CustomRPC([
            "mcp.servers.add": { _ in ["ok": true] },
            "mcp.servers.remove": { _ in ["ok": true] },
            "mcp.servers.oauth.start": rpcFailure(5000, message: "Dynamic client registration rejected"),
        ])
        do {
            _ = try await customService(refusing).beginMcpPaste(preset())
            Issue.record("expected a failure")
        } catch {
            #expect(error as? ConnectAppsError == .signInFailed(McpSignInFailure.registrationRejected.reason))
        }
        #expect(refusing.methods().last == "mcp.servers.remove")
    }

    @Test func anAuthorizationLinkWithoutStateIsRefused() async {
        let rpc = gateway(url: "https://auth.example.com/authorize?response_type=code")
        do {
            _ = try await customService(rpc).beginMcpPaste(preset())
            Issue.record("expected a failure")
        } catch {
            #expect(error as? ConnectAppsError == .signInFailed(McpSignInFailure.other.reason))
        }
        #expect(rpc.methods().contains("mcp.servers.oauth.cancel"))
    }

    @Test func thePastedValueNeverAppearsInDescriptions() async throws {
        let canary = "CANARY-\(UUID().uuidString)"
        let rpc = gateway()
        let session = try await customService(rpc).beginMcpPaste(preset())
        _ = await session.submit("\(redirect)?code=\(canary)&state=st-1")
        #expect(!String(describing: session).contains(canary))
        #expect(!String(reflecting: session).contains(canary))
        #expect(!"\(Mirror(reflecting: session).children)".contains(canary))
    }
}
