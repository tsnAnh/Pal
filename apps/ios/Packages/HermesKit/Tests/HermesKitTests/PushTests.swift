import Foundation
@testable import HermesAuth
@testable import HermesClient
import HermesDiagnostics
import HermesProtocol
import HermesREST
import HermesTransport
import Synchronization
import Testing

private let tokenBytes = Data((0..<32).map { UInt8($0 * 7 % 256) })
private let tokenHex = "00070e151c232a31383f464d545b626970777e858c939aa1a8afb6bdc4cbd2d9"

private final class PushGateway: Sendable {
    private let log = Mutex<[(method: String, params: JSONValue?, connection: Int)]>([])
    private let helloRecorded: Bool
    private let registerReply: Mutex<FakeGateway.Reply?>

    init(helloRecorded: Bool = true, registerReply: FakeGateway.Reply? = nil) {
        self.helloRecorded = helloRecorded
        self.registerReply = Mutex(registerReply)
    }

    func handle(_ method: String, _ params: JSONValue?, _ connection: Int) -> FakeGateway.Reply {
        log.withLock { $0.append((method, params, connection)) }
        switch method {
        case "runtime.describe":
            return .result(["instance_id": "i1", "profile_id": "p1", "authority_epoch": 1, "capabilities": ["reach-v1"]])
        case "client.hello":
            return .result(["recorded": .bool(helloRecorded), "same_host": false])
        case "client.attention":
            return .result(["recorded": true])
        case "push.register":
            return registerReply.withLock { $0 } ?? .result(["registered": true, "push_enabled": true])
        case "push.unregister":
            return .result(["removed": true])
        default:
            return .failure(RPCError(code: -32601, message: "unknown_method", data: ["reason": "unknown_method"]))
        }
    }

    func calls(_ method: String) -> [(method: String, params: JSONValue?, connection: Int)] {
        log.withLock { $0.filter { $0.method == method } }
    }

    var methods: [String] { log.withLock { $0.map(\.method) } }
}

private struct StubTickets: HTTPTransport {
    func send(_ request: URLRequest) async throws -> HTTPResult {
        let body = Data(#"{"ticket":"push-test-ticket","ttl_seconds":60}"#.utf8)
        return HTTPResult(data: body, response: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private let deviceID = "0B7F3F2E-5A4B-4E5E-9D1C-1F2E3D4C5B6A"

private func registration(environment: PushEnvironment = .sandbox) -> PushRegistration {
    PushRegistration(token: PushToken(deviceToken: tokenBytes)!, environment: environment, bundleID: "dev.tsnanh.hermes.bot")!
}

private func connect(
    _ gateway: FakeGateway,
    presence: ReachPresence,
    diagnostics: Diagnostics = .silent
) async throws -> GatewayConnection {
    let port = try #require(gateway.url.port)
    let base = try GatewayBaseURL(validating: "http://127.0.0.1:\(port)")
    let tokens = TokenSet(accessToken: "access-token-1", refreshToken: "refresh-token-1", expiresAt: Date().addingTimeInterval(3600))
    let auth = try AuthSession(store: InMemoryCredentialStore(StoredCredentials(baseURL: base, tokens: tokens)), transport: StubTickets())
    return try await HermesClient(auth: auth, transport: StubTickets(), diagnostics: diagnostics, presence: presence).connect()
}

private func eventually(_ condition: @Sendable () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

@Suite("Push token")
struct PushTokenTests {
    @Test("the token is lowercase hex of the device token bytes")
    func hex() throws {
        #expect(try #require(PushToken(deviceToken: tokenBytes)).hex == tokenHex)
    }

    @Test("a device token the gateway would refuse is never built", arguments: [0, 1, 15, 101, 4096])
    func outOfRange(count: Int) {
        #expect(PushToken(deviceToken: Data(repeating: 0xAB, count: count)) == nil)
    }

    @Test("the token never appears when the value is printed")
    func redacted() throws {
        let token = try #require(PushToken(deviceToken: tokenBytes))
        #expect(!"\(token)".contains(tokenHex))
        #expect(!String(reflecting: token).contains(tokenHex))
        #expect(!"\(registration())".contains(tokenHex))
    }

    @Test("register params match the canonical contract exactly")
    func registerParams() {
        #expect(PushWire.registerParams(deviceID: deviceID, registration: registration()) == [
            "device_id": .string(deviceID), "apns_token": .string(tokenHex), "environment": "sandbox", "bundle_id": "dev.tsnanh.hermes.bot",
        ])
        #expect(PushWire.registerParams(deviceID: deviceID, registration: registration(environment: .production))["environment"] == "production")
        #expect(PushWire.unregisterParams(deviceID: deviceID) == ["device_id": .string(deviceID)])
    }

    @Test("a bundle id outside the contract pattern is not registrable", arguments: ["", "ab", "has space", "emoji\u{1F600}.app", String(repeating: "a", count: 156)])
    func badBundle(id: String) {
        #expect(PushRegistration(token: PushToken(deviceToken: tokenBytes)!, environment: .sandbox, bundleID: id) == nil)
    }
}

@Suite("Push registration over a gateway")
struct PushRegistrationTests {
    @Test("a registration is sent after the hello that declared the device")
    func registersAfterHello() async throws {
        let script = PushGateway()
        let gateway = try await FakeGateway.start { script.handle($0, $1, $2) }
        defer { gateway.stop() }
        let presence = ReachPresence(identity: DeviceIdentity(deviceID: deviceID, formFactor: .phone, appVersion: "1"))
        await presence.setPushRegistration(registration())
        let connection = try await connect(gateway, presence: presence)
        defer { Task { await connection.close() } }
        #expect(await eventually { !script.calls("push.register").isEmpty })
        let call = try #require(script.calls("push.register").first)
        #expect(call.params == PushWire.registerParams(deviceID: deviceID, registration: registration()))
        #expect(script.methods.firstIndex(of: "client.hello")! < script.methods.firstIndex(of: "push.register")!)
    }

    @Test("a token that arrives after the connection is registered on the live connection")
    func lateToken() async throws {
        let script = PushGateway()
        let gateway = try await FakeGateway.start { script.handle($0, $1, $2) }
        defer { gateway.stop() }
        let presence = ReachPresence(identity: DeviceIdentity(deviceID: deviceID, formFactor: .phone, appVersion: "1"))
        let connection = try await connect(gateway, presence: presence)
        defer { Task { await connection.close() } }
        #expect(script.calls("push.register").isEmpty)
        await presence.setPushRegistration(registration())
        #expect(script.calls("push.register").count == 1)
    }

    @Test("a refused hello means no push registration")
    func noHelloNoRegistration() async throws {
        let script = PushGateway(helloRecorded: false)
        let gateway = try await FakeGateway.start { script.handle($0, $1, $2) }
        defer { gateway.stop() }
        let presence = ReachPresence(identity: DeviceIdentity(deviceID: deviceID, formFactor: .phone, appVersion: "1"))
        await presence.setPushRegistration(registration())
        let connection = try await connect(gateway, presence: presence)
        defer { Task { await connection.close() } }
        await presence.setPushRegistration(registration())
        #expect(script.calls("push.register").isEmpty)
    }

    @Test("a refused registration leaves the connection usable and the token out of diagnostics")
    func refusedRegistration() async throws {
        let refusal = RPCError(code: 4001, message: "hello_required", data: ["reason": "hello_required"])
        let script = PushGateway(registerReply: .failure(refusal))
        let gateway = try await FakeGateway.start { script.handle($0, $1, $2) }
        defer { gateway.stop() }
        let recorder = DiagnosticRecorder()
        let presence = ReachPresence(identity: DeviceIdentity(deviceID: deviceID, formFactor: .phone, appVersion: "1"), diagnostics: recorder.diagnostics)
        await presence.setPushRegistration(registration())
        let connection = try await connect(gateway, presence: presence, diagnostics: recorder.diagnostics)
        defer { Task { await connection.close() } }
        #expect(await eventually { !script.calls("push.register").isEmpty })
        _ = try await connection.call("client.attention", params: ["state": "background"])
        #expect(!recorder.transcript.contains(tokenHex))
    }

    @Test("a reconnect registers again on the new connection")
    func reconnect() async throws {
        let script = PushGateway()
        let gateway = try await FakeGateway.start { script.handle($0, $1, $2) }
        defer { gateway.stop() }
        let presence = ReachPresence(identity: DeviceIdentity(deviceID: deviceID, formFactor: .phone, appVersion: "1"))
        await presence.setPushRegistration(registration())
        let first = try await connect(gateway, presence: presence)
        #expect(await eventually { script.calls("push.register").count == 1 })
        await first.close()
        let second = try await connect(gateway, presence: presence)
        defer { Task { await second.close() } }
        #expect(await eventually { script.calls("push.register").count == 2 })
    }

    @Test("signing out unregisters this device and forgets the token")
    func unregister() async throws {
        let script = PushGateway()
        let gateway = try await FakeGateway.start { script.handle($0, $1, $2) }
        defer { gateway.stop() }
        let presence = ReachPresence(identity: DeviceIdentity(deviceID: deviceID, formFactor: .phone, appVersion: "1"))
        await presence.setPushRegistration(registration())
        let connection = try await connect(gateway, presence: presence)
        defer { Task { await connection.close() } }
        #expect(await eventually { script.calls("push.register").count == 1 })
        await presence.unregisterPush()
        #expect(script.calls("push.unregister").first?.params == PushWire.unregisterParams(deviceID: deviceID))
        let second = try await connect(gateway, presence: presence)
        defer { Task { await second.close() } }
        try await Task.sleep(for: .milliseconds(200))
        #expect(script.calls("push.register").count == 1)
    }
}

@Suite("Device identity on the wire")
struct DeviceIdentityWireTests {
    @Test("hello carries model and os when known and nothing extra when not")
    func helloModelAndOS() {
        let known = DeviceIdentity(deviceID: deviceID, formFactor: .phone, appVersion: "1", model: "iPhone18,1", os: "iOS 26.1")
        let params = ReachWire.helloParams(identity: known, acceptsOffers: false, attention: .foreground)
        #expect(params["model"] == "iPhone18,1")
        #expect(params["os"] == "iOS 26.1")
        let unknown = DeviceIdentity(deviceID: deviceID, formFactor: .phone, appVersion: "1")
        let bare = ReachWire.helloParams(identity: unknown, acceptsOffers: false, attention: .foreground)
        #expect(bare["model"] == nil)
        #expect(bare["os"] == nil)
    }

    @Test("model and os are bounded to the contract length")
    func bounded() {
        let long = String(repeating: "x", count: 80)
        let identity = DeviceIdentity(deviceID: deviceID, formFactor: .phone, appVersion: "1", model: long, os: long)
        #expect(identity.model.count == DeviceIdentity.maximumHardwareLength)
        #expect(identity.os.count == DeviceIdentity.maximumHardwareLength)
    }
}

private final class BodyRecordingTransport: HTTPTransport, @unchecked Sendable {
    private let bodies = Mutex<[(path: String, body: JSONValue)]>([])

    var requests: [(path: String, body: JSONValue)] { bodies.withLock { $0 } }

    func send(_ request: URLRequest) async throws -> HTTPResult {
        let body = (try? JSONDecoder().decode(JSONValue.self, from: request.httpBody ?? Data())) ?? .null
        bodies.withLock { $0.append((request.url?.path ?? "", body)) }
        let payload = Data(#"{"access_token":"a2","refresh_token":"r2"}"#.utf8)
        return HTTPResult(data: payload, response: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@Suite("Device id on sign-in")
struct DeviceGrantTests {
    private func credentials() throws -> StoredCredentials {
        let base = try GatewayBaseURL(validating: "https://hermes.example.com")
        return StoredCredentials(baseURL: base, tokens: TokenSet(accessToken: "a1", refreshToken: "r1", expiresAt: Date(timeIntervalSinceNow: -10)))
    }

    @Test("a refresh names the device so the gateway keeps the grant bound to it")
    func refreshCarriesDevice() async throws {
        let transport = BodyRecordingTransport()
        let auth = try AuthSession(store: InMemoryCredentialStore(try credentials()), transport: transport, deviceID: deviceID)
        _ = try await auth.accessToken()
        let request = try #require(transport.requests.first)
        #expect(request.path == "/auth/native/refresh")
        #expect(request.body["device_id"] == .string(deviceID))
    }

    @Test("without a device id the refresh body has none")
    func refreshWithoutDevice() async throws {
        let transport = BodyRecordingTransport()
        let auth = try AuthSession(store: InMemoryCredentialStore(try credentials()), transport: transport)
        _ = try await auth.accessToken()
        #expect(transport.requests.first?.body["device_id"] == nil)
    }

    @Test("a device id the gateway would reject is never sent")
    func invalidDeviceDropped() async throws {
        let transport = BodyRecordingTransport()
        let auth = try AuthSession(store: InMemoryCredentialStore(try credentials()), transport: transport, deviceID: "bad id!")
        _ = try await auth.accessToken()
        #expect(transport.requests.first?.body["device_id"] == nil)
    }
}

@Suite("Device id on the code exchange")
struct DeviceCodeExchangeTests {
    @Test("the code exchange names the device, and drops an invalid one")
    func exchangeCarriesDevice() async throws {
        let base = try GatewayBaseURL(validating: "https://hermes.example.com")
        let cases: [(given: String?, expected: JSONValue?)] = [(deviceID, .string(deviceID)), ("bad id!", nil), (nil, nil)]
        for (given, expected) in cases {
            let transport = BodyRecordingTransport()
            let api = NativeAuthAPI(baseURL: base, transport: transport, diagnostics: .silent, now: { Date() }, deviceID: given)
            _ = try await api.exchange(code: "code-1", verifier: "verifier-1")
            let request = try #require(transport.requests.first)
            #expect(request.path == "/auth/native/token")
            #expect(request.body["device_id"] == expected)
            #expect(request.body["code_verifier"] == "verifier-1")
        }
    }
}

@Suite("Push payload")
struct PushPayloadTests {
    private func payload(profile: Any? = "cho-ua", session: Any? = "20260508_101010_abc") -> [AnyHashable: Any] {
        var info: [AnyHashable: Any] = ["aps": ["alert": ["title": "chó UA", "body": "Finished"], "thread-id": "cho-ua"]]
        if let profile { info["profile"] = profile }
        if let session { info["session_id"] = session }
        return info
    }

    @Test("the payload the gateway builds opens that bot's chat")
    func gatewayPayload() {
        #expect(PushWire.target(fromUserInfo: payload()) == PushTarget(profile: "cho-ua", sessionID: "20260508_101010_abc"))
    }

    @Test("the session id is optional")
    func noSession() {
        #expect(PushWire.target(fromUserInfo: payload(session: nil)) == PushTarget(profile: "cho-ua", sessionID: nil))
        #expect(PushWire.target(fromUserInfo: payload(session: 42))?.sessionID == nil)
        #expect(PushWire.target(fromUserInfo: payload(session: String(repeating: "s", count: 200)))?.sessionID == nil)
    }

    @Test("a notification naming no usable bot opens nothing", arguments: ["", "../etc/passwd", "a b", "bot/other", String(repeating: "a", count: 65)])
    func unusableProfile(profile: String) {
        #expect(PushWire.target(fromUserInfo: payload(profile: profile)) == nil)
    }

    @Test("a notification without a text profile opens nothing")
    func missingProfile() {
        #expect(PushWire.target(fromUserInfo: payload(profile: nil)) == nil)
        #expect(PushWire.target(fromUserInfo: payload(profile: 7)) == nil)
        #expect(PushWire.target(fromUserInfo: ["aps": [:]]) == nil)
    }

    @Test("the default bot and dotted or underscored names are usable")
    func usableNames() {
        for name in ["default", "market_researcher", "a.b-c", "Bot9"] {
            #expect(PushWire.target(fromUserInfo: payload(profile: name))?.profile == name)
        }
    }
}
