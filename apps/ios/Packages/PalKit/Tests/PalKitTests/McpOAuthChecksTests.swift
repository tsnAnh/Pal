import Foundation
import PalAuth
@testable import PalConnect
import PalProtocol
import PalREST
import PalTransport
import Synchronization
import Testing

@Suite("MCP OAuth scopes and callback checks")
struct McpOAuthChecksTests {
    @Test func requestsEveryScopeTheServerOffersOrNone() {
        #expect(McpOAuthScopes.requested(resourceScopes: nil, serverScopes: nil) == nil)
        #expect(McpOAuthScopes.requested(resourceScopes: [], serverScopes: []) == nil)
        #expect(McpOAuthScopes.requested(resourceScopes: nil, serverScopes: ["a", "b", "a"]) == "a b")
        #expect(McpOAuthScopes.requested(resourceScopes: ["r"], serverScopes: ["a", "b"]) == "r")
    }

    @Test func acceptsOnlyAMatchingStateWithACode() throws {
        #expect(try AuthorizationCallback.code(from: ["code": "c", "state": "s"], expectedState: "s") == "c")
        #expect(throws: SignInError.stateMismatch) { try AuthorizationCallback.code(from: ["code": "c", "state": "x"], expectedState: "s") }
        #expect(throws: SignInError.stateMismatch) { try AuthorizationCallback.code(from: ["code": "c"], expectedState: "s") }
        #expect(throws: SignInError.authorizationDenied("access_denied")) {
            try AuthorizationCallback.code(from: ["error": "access_denied", "state": "s"], expectedState: "s")
        }
        #expect(throws: SignInError.missingAuthorizationCode) { try AuthorizationCallback.code(from: ["state": "s"], expectedState: "s") }
    }

    @Test func comparesStatesInFull() {
        #expect(ConstantTime.equal("abc", "abc"))
        #expect(!ConstantTime.equal("abc", "abd"))
        #expect(!ConstantTime.equal("abc", "abcd"))
        #expect(!ConstantTime.equal("", "a"))
        #expect(ConstantTime.equal("", ""))
    }

    @Test func readsTheResourceMetadataHint() {
        let header = #"Bearer realm="mcp", resource_metadata="https://mcp.upwork.com/.well-known/oauth-protected-resource""#
        #expect(McpOAuthDiscovery.resourceMetadataURL(inChallenge: header)?.absoluteString == "https://mcp.upwork.com/.well-known/oauth-protected-resource")
        #expect(McpOAuthDiscovery.resourceMetadataURL(inChallenge: "Bearer realm=\"mcp\"") == nil)
    }
}

@Suite("Loopback listener state and reuse")
struct LoopbackStateTests {
    @Test func ignoresAWrongStateThenAcceptsTheRightOne() async throws {
        let listener = try await LoopbackRedirectListener.start(timeout: .seconds(10), expectedState: "good")
        async let parameters = listener.awaitCallback()
        let (_, bad) = try await URLSession.shared.data(from: URL(string: "\(listener.redirectURI)?code=a&state=bad")!)
        let (_, missing) = try await URLSession.shared.data(from: URL(string: "\(listener.redirectURI)?code=a")!)
        #expect((bad as? HTTPURLResponse)?.statusCode == 400)
        #expect((missing as? HTTPURLResponse)?.statusCode == 400)
        let (_, good) = try await URLSession.shared.data(from: URL(string: "\(listener.redirectURI)?code=a&state=good")!)
        #expect((good as? HTTPURLResponse)?.statusCode == 200)
        #expect(try await parameters == ["code": "a", "state": "good"])
    }

    @Test func aSecondCallbackIsRefused() async throws {
        let listener = try await LoopbackRedirectListener.start(timeout: .seconds(10), expectedState: "s")
        async let parameters = listener.awaitCallback()
        _ = try await URLSession.shared.data(from: URL(string: "\(listener.redirectURI)?code=a&state=s")!)
        _ = try await parameters
        let second = try? await URLSession.shared.data(from: URL(string: "\(listener.redirectURI)?code=b&state=s")!)
        if let second { #expect((second.1 as? HTTPURLResponse)?.statusCode == 410) }
    }
}
