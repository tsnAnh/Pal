import Foundation
import PalAuth
@testable import PalConnect
import PalDiagnostics
import PalREST
import Synchronization
import Testing

private final class LoopbackAuthServer: HTTPTransport, @unchecked Sendable {
    let resource: String
    let authorizationServer: String
    private let log = Mutex<[URL]>([])

    init(resource: String, authorizationServer: String) {
        self.resource = resource
        self.authorizationServer = authorizationServer
    }

    var urls: [URL] { log.withLock { $0 } }

    func send(_ request: URLRequest) async throws -> HTTPResult {
        let url = request.url!
        log.withLock { $0.append(url) }
        let body: [String: Any]
        var status = 200
        var headers: [String: String] = [:]
        switch url.path {
        case "/mcp":
            status = 401
            body = [:]
            headers["WWW-Authenticate"] = #"Bearer resource_metadata="\#(resource.replacingOccurrences(of: "/mcp", with: ""))/.well-known/oauth-protected-resource/mcp""#
        case "/.well-known/oauth-protected-resource/mcp":
            body = ["resource": resource, "authorization_servers": [authorizationServer], "scopes_supported": ["orchestration:read", "orchestration:operate"]]
        case "/.well-known/oauth-authorization-server":
            body = [
                "issuer": authorizationServer, "authorization_endpoint": authorizationServer + "/oauth/mcp/authorize",
                "token_endpoint": authorizationServer + "/oauth/mcp/token", "registration_endpoint": authorizationServer + "/oauth/mcp/register",
                "code_challenge_methods_supported": ["S256"],
            ]
        default:
            status = 404
            body = [:]
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        return HTTPResult(data: try JSONSerialization.data(withJSONObject: body), response: response)
    }
}

@Suite("MCP OAuth discovery on loopback")
struct McpOAuthLoopbackTests {
    private func discover(resource: String, server: LoopbackAuthServer) async throws -> McpOAuthServer {
        try await McpOAuthDiscovery(http: McpOAuthHTTP(transport: server), diagnostics: .silent).discover(resource: URL(string: resource)!)
    }

    @Test func aLoopbackServerSignsInOverPlainHTTPWithItsOwnScopes() async throws {
        let origin = "http://127.0.0.1:47391"
        let server = LoopbackAuthServer(resource: origin + "/mcp", authorizationServer: origin)
        let found = try await discover(resource: origin + "/mcp", server: server)
        #expect(found.authorizationEndpoint.absoluteString == origin + "/oauth/mcp/authorize")
        #expect(found.registrationEndpoint.absoluteString == origin + "/oauth/mcp/register")
        #expect(found.scope == "orchestration:read orchestration:operate")
        #expect(found.resource == origin + "/mcp")
    }

    @Test func aLoopbackResourceCannotPointSignInAtAnotherHost() async {
        let origin = "http://127.0.0.1:47391"
        let server = LoopbackAuthServer(resource: origin + "/mcp", authorizationServer: "http://192.168.1.9:80")
        await #expect(throws: McpOAuthError.discoveryFailed) { try await discover(resource: origin + "/mcp", server: server) }
        #expect(server.urls.allSatisfy { $0.host() == "127.0.0.1" })
    }

    @Test func plainHTTPToARemoteHostIsStillRefused() async {
        let server = LoopbackAuthServer(resource: "http://mcp.example.com/mcp", authorizationServer: "http://mcp.example.com")
        await #expect(throws: McpOAuthError.discoveryFailed) { try await discover(resource: "http://mcp.example.com/mcp", server: server) }
        #expect(server.urls.isEmpty)
    }

    @Test func aRemoteHTTPSResourceCannotSteerSignInToLoopback() async {
        let server = LoopbackAuthServer(resource: "https://mcp.example.com/mcp", authorizationServer: "http://127.0.0.1:9999")
        let result = try? await discover(resource: "https://mcp.example.com/mcp", server: server)
        #expect(result?.authorizationEndpoint.host() != "127.0.0.1")
        #expect(server.urls.allSatisfy { $0.host() != "127.0.0.1" })
    }

    @Test func loopbackHostMatchingIsExact() {
        for host in ["127.0.0.1", "localhost", "LOCALHOST", "::1", "[::1]"] { #expect(LoopbackHost.isLoopback(host)) }
        for host in ["127.0.0.2", "0.0.0.0", "localhost.evil.com", "evil-localhost", "", "example.com"] { #expect(!LoopbackHost.isLoopback(host)) }
    }
}
