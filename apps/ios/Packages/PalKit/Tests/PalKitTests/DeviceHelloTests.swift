import Foundation
import PalAuth
import PalClient
import PalProtocol
import PalREST
import PalTransport
import Synchronization
import Testing

private struct TicketTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> HTTPResult {
        let body = Data(#"{"ticket":"hello-test-ticket","ttl_seconds":60}"#.utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return HTTPResult(data: body, response: response)
    }
}

private func client(for gateway: FakeGateway) throws -> PalClient {
    let port = try #require(gateway.url.port)
    let base = try GatewayBaseURL(validating: "http://127.0.0.1:\(port)")
    let tokens = TokenSet(accessToken: "access-token-1", refreshToken: "refresh-token-1", expiresAt: Date().addingTimeInterval(3600))
    let auth = try AuthSession(store: InMemoryCredentialStore(StoredCredentials(baseURL: base, tokens: tokens)), transport: TicketTransport())
    let identity = DeviceIdentity(deviceID: "0B7F3F2E-5A4B-4E5E-9D1C-1F2E3D4C5B6A", formFactor: .phone, appVersion: "0.1.0 (7)")
    return PalClient(auth: auth, transport: TicketTransport(), presence: ReachPresence(identity: identity))
}

private func gateway(capabilities: [String], hello: @escaping @Sendable (JSONValue?) -> FakeGateway.Reply) async throws -> FakeGateway {
    try await FakeGateway.start { method, params, _ in
        switch method {
        case "runtime.describe":
            .result(["instance_id": "i1", "profile_id": "p1", "authority_epoch": 1, "capabilities": .array(capabilities.map(JSONValue.string))])
        case "client.hello": hello(params)
        case "client.attention": .result(["recorded": true])
        default: .failure(RPCError(code: -32601, message: "unknown_method"))
        }
    }
}

@Suite("Device host hello")
struct DeviceHelloTests {
    @Test func theDeviceHostDeclaresDeviceToolsAndNothingElseDoes() async throws {
        let hellos = Mutex<[JSONValue]>([])
        let fake = try await gateway(capabilities: ["reach-v1"]) { params in
            if let params { hellos.withLock { $0.append(params) } }
            return .result(["recorded": true, "same_host": false])
        }
        let client = try client(for: fake)
        let host = try await client.connect(reach: .deviceHost)
        let roster = try await client.connect(reach: .offerTarget)
        let chat = try await client.connect()
        let sent = hellos.withLock { $0 }
        #expect(sent.count == 3)
        #expect(sent[0]["device_tools"]?.boolValue == true)
        #expect(sent[0]["accepts_offers"]?.boolValue == false)
        #expect(sent[1]["device_tools"] == nil && sent[1]["accepts_offers"]?.boolValue == true)
        #expect(sent[2]["device_tools"] == nil)
        await host.close()
        await roster.close()
        await chat.close()
        fake.stop()
    }

    @Test func aGatewayWithoutReachCannotHostDeviceTools() async throws {
        let fake = try await gateway(capabilities: []) { _ in .result(["recorded": true, "same_host": false]) }
        await #expect(throws: PalClientError.deviceToolsUnavailable) { try await client(for: fake).connect(reach: .deviceHost) }
        fake.stop()
    }

    @Test func anUnrecordedHelloCannotHostDeviceTools() async throws {
        let fake = try await gateway(capabilities: ["reach-v1"]) { _ in .result(["recorded": false, "same_host": false]) }
        await #expect(throws: PalClientError.deviceToolsUnavailable) { try await client(for: fake).connect(reach: .deviceHost) }
        fake.stop()
    }
}
