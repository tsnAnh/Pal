import Foundation
import PalDevice
import PalProtocol
import PalT3Code
import Synchronization
import Testing

final class RelayRecorder: Sendable {
    private let delivered = Mutex<[(relay: String, message: JSONValue)]>([])
    private let failed = Mutex<[(relay: String, code: DeviceMcpFailCode, text: String)]>([])
    private let accepting = Mutex(true)
    private let unauthorizedCount = Mutex(0)

    var deliveries: [(relay: String, message: JSONValue)] { delivered.withLock { $0 } }
    var failures: [(relay: String, code: DeviceMcpFailCode, text: String)] { failed.withLock { $0 } }
    var unauthorized: Int { unauthorizedCount.withLock { $0 } }

    func refuseDeliveries() { accepting.withLock { $0 = false } }
    func noteUnauthorized() { unauthorizedCount.withLock { $0 += 1 } }

    func ids(_ relay: String) -> [Int] {
        deliveries.filter { $0.relay == relay }.compactMap { $0.message["id"]?.intValue }
    }

    var channel: DeviceMcpChannel {
        DeviceMcpChannel(
            deliver: { [self] relay, message in
                guard accepting.withLock({ $0 }) else { return false }
                delivered.withLock { $0.append((relay, message)) }
                return true
            },
            fail: { [self] relay, code, text in failed.withLock { $0.append((relay, code, text)) } }
        )
    }
}

func awaitCondition(_ timeout: Duration = .seconds(10), _ condition: @Sendable () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

struct T3Sandbox {
    let directory: URL
    let runtimeFile: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "t3-sandbox-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory.appending(path: "userdata"), withIntermediateDirectories: true)
        runtimeFile = directory.appending(path: "userdata/server-runtime.json")
    }

    var locator: T3Locator {
        T3Locator(runtimeFile: runtimeFile, applicationDirectories: [directory], processAlive: { _ in true })
    }

    func publish(origin: String, version: Int = 1, pid: Int = 4242) throws {
        try Data(#"{"version":\#(version),"pid":\#(pid),"origin":"\#(origin)"}"#.utf8).write(to: runtimeFile)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

final class FakeT3: Sendable {
    static let goodToken = "good-token"
    let sessionID = "t3-session-1"
    let initializeDelay = Mutex(Duration.zero)

    func handle(_ request: StubRequest) async -> StubReply {
        if request.method == "DELETE" { return .status(200) }
        guard request.headers["authorization"] == "Bearer \(Self.goodToken)" else {
            return .json(401, #"{"error":"invalid_mcp_credential"}"#, headers: ["WWW-Authenticate": "Bearer"])
        }
        let id = request.json?["id"].map { "\($0)" } ?? "null"
        switch request.rpcMethod {
        case "initialize":
            let delay = initializeDelay.withLock { $0 }
            let reply = StubReply.json(200, #"{"jsonrpc":"2.0","id":\#(id),"result":{"protocolVersion":"2025-06-18"}}"#, headers: ["Mcp-Session-Id": sessionID])
            return delay == .zero ? reply : .delayed(delay, reply)
        case "notifications/initialized":
            return request.headers["mcp-session-id"] == sessionID ? .status(202) : .status(400)
        case "tools/list":
            let tools = #"{"jsonrpc":"2.0","id":\#(id),"result":{"tools":[{"name":"t3_thread_wait"}]}}"#
            return request.headers["mcp-session-id"] == sessionID ? .json(200, tools) : .status(400)
        case "events":
            return .events([
                (.zero, ": priming\n\n"),
                (.zero, "data:\n\n"),
                (.zero, #"data: {"jsonrpc":"2.0","method":"notifications/progress","params":{"n":1}}"# + "\n\n"),
                (.milliseconds(30), #"data: {"jsonrpc":"2.0","id":\#(id),"result":{"done":true}}"# + "\r\n\r\n"),
            ])
        case "wait":
            return .delayed(.milliseconds(1500), .json(200, #"{"jsonrpc":"2.0","id":\#(id),"result":{"waited":true}}"#))
        case "ping":
            return .json(200, #"{"jsonrpc":"2.0","id":\#(id),"result":{}}"#)
        case "bad":
            return .json(400, #"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32602,"message":"bad"}}"#)
        case "huge":
            return .json(200, #"{"jsonrpc":"2.0","id":\#(id),"result":""#  + String(repeating: "a", count: DeviceMcpLimits.maximumMessageBytes + 10) + #""}"#)
        case "hugeevent":
            return .events([(.zero, "data: " + String(repeating: "a", count: DeviceMcpLimits.maximumMessageBytes + 10) + "\n\n")])
        case "redirect":
            return .status(302, headers: ["Location": "http://127.0.0.1:1/elsewhere"])
        default:
            return .status(500)
        }
    }
}

private func request(_ id: Int, _ method: String) -> JSONValue {
    ["jsonrpc": "2.0", "id": .int(id), "method": .string(method)]
}

private func frame(_ relay: String, _ message: JSONValue) -> DeviceMcpFrame {
    DeviceMcpFrame(relayID: relay, server: .t3code, message: message)
}

private struct BridgeRig {
    let fake: FakeT3
    let server: T3StubServer
    let sandbox: T3Sandbox
    let recorder: RelayRecorder
    let bridge: T3McpBridge

    func stop() {
        server.stop()
        sandbox.remove()
    }
}

private func bridgeRig(token: String? = FakeT3.goodToken) async throws -> BridgeRig {
    let fake = FakeT3()
    let server = try await T3StubServer.start { await fake.handle($0) }
    let sandbox = try T3Sandbox()
    try sandbox.publish(origin: server.origin)
    let recorder = RelayRecorder()
    let tokens = InMemoryT3TokenStore(token.map { T3Token(access: SecretString($0), expiresAt: nil) })
    let bridge = T3McpBridge(locator: sandbox.locator, tokens: tokens, onUnauthorized: { recorder.noteUnauthorized() })
    return BridgeRig(fake: fake, server: server, sandbox: sandbox, recorder: recorder, bridge: bridge)
}

@Suite("T3 MCP bridge")
struct T3McpBridgeTests {
    @Test func initializeIsForwardedWithTheTokenAndItsSessionIsReused() async throws {
        let rig = try await bridgeRig()
        defer { rig.stop() }
        await rig.bridge.relay(frame("r1", request(1, "initialize")), over: rig.recorder.channel)
        #expect(await awaitCondition { rig.recorder.ids("r1") == [1] })
        await rig.bridge.relay(frame("r1", request(2, "tools/list")), over: rig.recorder.channel)
        #expect(await awaitCondition { rig.recorder.ids("r1") == [1, 2] })
        let first = try #require(rig.server.requests.first)
        #expect(first.path == "/mcp")
        #expect(first.headers["authorization"] == "Bearer good-token")
        #expect(first.headers["accept"] == "application/json, text/event-stream")
        #expect(first.headers["mcp-protocol-version"] == "2025-06-18")
        #expect(first.headers["mcp-session-id"] == nil)
        let second = try #require(rig.server.requests.last)
        #expect(second.headers["mcp-session-id"] == "t3-session-1")
        #expect(rig.recorder.failures.isEmpty)
    }

    @Test func eachServerSentEventBecomesOneDeliveryAndEmptyOnesAreSkipped() async throws {
        let rig = try await bridgeRig()
        defer { rig.stop() }
        await rig.bridge.relay(frame("r1", request(7, "events")), over: rig.recorder.channel)
        #expect(await awaitCondition { rig.recorder.deliveries.count == 2 })
        #expect(rig.recorder.deliveries[0].message["method"]?.stringValue == "notifications/progress")
        #expect(rig.recorder.deliveries[1].message["result"]?["done"]?.boolValue == true)
    }

    @Test func anAcceptedNotificationDeliversNothing() async throws {
        let rig = try await bridgeRig()
        defer { rig.stop() }
        await rig.bridge.relay(frame("r1", request(1, "initialize")), over: rig.recorder.channel)
        #expect(await awaitCondition { rig.recorder.ids("r1") == [1] })
        await rig.bridge.relay(frame("r1", ["jsonrpc": "2.0", "method": "notifications/initialized"]), over: rig.recorder.channel)
        #expect(await awaitCondition { rig.server.requests.count == 2 })
        try await Task.sleep(for: .milliseconds(200))
        #expect(rig.recorder.deliveries.count == 1)
        #expect(rig.recorder.failures.isEmpty)
    }

    @Test func framesArrivingBeforeInitializeFinishesAreSentInArrivalOrderWithTheSession() async throws {
        let rig = try await bridgeRig()
        defer { rig.stop() }
        rig.fake.initializeDelay.withLock { $0 = .milliseconds(400) }
        await rig.bridge.relay(frame("r1", request(1, "initialize")), over: rig.recorder.channel)
        await rig.bridge.relay(frame("r1", ["jsonrpc": "2.0", "method": "notifications/initialized"]), over: rig.recorder.channel)
        await rig.bridge.relay(frame("r1", request(2, "tools/list")), over: rig.recorder.channel)
        #expect(await awaitCondition { rig.recorder.ids("r1") == [1, 2] })
        let methods = rig.server.requests.compactMap(\.rpcMethod)
        #expect(methods == ["initialize", "notifications/initialized", "tools/list"])
        #expect(rig.server.requests.dropFirst().allSatisfy { $0.headers["mcp-session-id"] == "t3-session-1" })
    }

    @Test func aLongPollDoesNotBlockLaterRequests() async throws {
        let rig = try await bridgeRig()
        defer { rig.stop() }
        await rig.bridge.relay(frame("r1", request(1, "initialize")), over: rig.recorder.channel)
        #expect(await awaitCondition { rig.recorder.ids("r1") == [1] })
        await rig.bridge.relay(frame("r1", request(2, "wait")), over: rig.recorder.channel)
        await rig.bridge.relay(frame("r1", request(3, "ping")), over: rig.recorder.channel)
        #expect(await awaitCondition { rig.recorder.ids("r1").contains(3) })
        #expect(!rig.recorder.ids("r1").contains(2))
        #expect(await awaitCondition { rig.recorder.ids("r1") == [1, 3, 2] })
    }

    @Test func aRejectedTokenFailsTheRelayAsAuthRequiredAndTellsTheOwner() async throws {
        let rig = try await bridgeRig(token: "stale-token")
        defer { rig.stop() }
        await rig.bridge.relay(frame("r1", request(1, "initialize")), over: rig.recorder.channel)
        #expect(await awaitCondition { rig.recorder.failures.count == 1 })
        #expect(rig.recorder.failures[0].code == .authRequired)
        #expect(rig.recorder.unauthorized == 1)
        #expect(await rig.bridge.openRelayCount == 0)
        #expect(!rig.recorder.failures[0].text.contains("stale-token"))
    }

    @Test func withoutASavedTokenNoRequestLeavesTheMac() async throws {
        let rig = try await bridgeRig(token: nil)
        defer { rig.stop() }
        await rig.bridge.relay(frame("r1", request(1, "initialize")), over: rig.recorder.channel)
        #expect(rig.recorder.failures.map(\.code) == [.authRequired])
        #expect(rig.recorder.unauthorized == 1)
        #expect(rig.server.requests.isEmpty)
    }

    @Test func aMissingRuntimeFileIsUnreachable() async throws {
        let rig = try await bridgeRig()
        defer { rig.stop() }
        try FileManager.default.removeItem(at: rig.sandbox.runtimeFile)
        await rig.bridge.relay(frame("r1", request(1, "initialize")), over: rig.recorder.channel)
        #expect(rig.recorder.failures.map(\.code) == [.unreachable])
        #expect(rig.server.requests.isEmpty)
    }

    @Test func aNonLoopbackRuntimeIsNeverContacted() async throws {
        let rig = try await bridgeRig()
        defer { rig.stop() }
        try rig.sandbox.publish(origin: "http://192.168.1.20:\(rig.server.port)")
        await rig.bridge.relay(frame("r1", request(1, "initialize")), over: rig.recorder.channel)
        #expect(rig.recorder.failures.map(\.code) == [.unreachable])
        #expect(rig.server.requests.isEmpty)
    }

    @Test func aRefusedConnectionIsUnreachableAndDropsTheRelay() async throws {
        let rig = try await bridgeRig()
        defer { rig.stop() }
        let dead = try await T3StubServer.start { _ in .status(200) }
        let port = dead.port
        dead.stop()
        try await Task.sleep(for: .milliseconds(100))
        try rig.sandbox.publish(origin: "http://127.0.0.1:\(port)")
        await rig.bridge.relay(frame("r1", request(1, "initialize")), over: rig.recorder.channel)
        #expect(await awaitCondition { rig.recorder.failures.count == 1 })
        #expect(rig.recorder.failures[0].code == .unreachable)
        #expect(await rig.bridge.openRelayCount == 0)
    }

    @Test func anOversizeClientMessageFailsTheRelayWithoutAnyRequest() async throws {
        let rig = try await bridgeRig()
        defer { rig.stop() }
        let big = JSONValue.object(["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": .string(String(repeating: "x", count: DeviceMcpLimits.maximumMessageBytes))])
        await rig.bridge.relay(frame("r1", big), over: rig.recorder.channel)
        #expect(rig.recorder.failures.map(\.code) == [.closed])
        #expect(rig.server.requests.isEmpty)
        #expect(rig.recorder.deliveries.isEmpty)
    }

    @Test func anOversizeJSONReplyFailsTheRelayAndIsNeverTruncated() async throws {
        let rig = try await bridgeRig()
        defer { rig.stop() }
        await rig.bridge.relay(frame("r1", request(1, "huge")), over: rig.recorder.channel)
        #expect(await awaitCondition { rig.recorder.failures.count == 1 })
        #expect(rig.recorder.failures[0].code == .closed)
        #expect(rig.recorder.deliveries.isEmpty)
        #expect(await rig.bridge.openRelayCount == 0)
    }

    @Test func anOversizeStreamedEventFailsTheRelay() async throws {
        let rig = try await bridgeRig()
        defer { rig.stop() }
        await rig.bridge.relay(frame("r1", request(1, "hugeevent")), over: rig.recorder.channel)
        #expect(await awaitCondition { rig.recorder.failures.count == 1 })
        #expect(rig.recorder.failures[0].code == .closed)
        #expect(rig.recorder.deliveries.isEmpty)
    }

    @Test func aMessageThatIsNotAnObjectFailsTheRelay() async throws {
        let rig = try await bridgeRig()
        defer { rig.stop() }
        await rig.bridge.relay(frame("r1", ["not", "an", "object"]), over: rig.recorder.channel)
        #expect(rig.recorder.failures.map(\.code) == [.closed])
        #expect(rig.server.requests.isEmpty)
    }

    @Test func closingARelayDeletesItsSessionAndStopsInFlightWork() async throws {
        let rig = try await bridgeRig()
        defer { rig.stop() }
        await rig.bridge.relay(frame("r1", request(1, "initialize")), over: rig.recorder.channel)
        #expect(await awaitCondition { rig.recorder.ids("r1") == [1] })
        await rig.bridge.relay(frame("r1", request(2, "wait")), over: rig.recorder.channel)
        try await Task.sleep(for: .milliseconds(100))
        await rig.bridge.close(DeviceMcpClose(relayID: "r1", reason: .clientClosed))
        #expect(await awaitCondition { rig.server.requests.contains { $0.method == "DELETE" } })
        let delete = try #require(rig.server.requests.first { $0.method == "DELETE" })
        #expect(delete.headers["mcp-session-id"] == "t3-session-1")
        #expect(delete.headers["authorization"] == "Bearer good-token")
        #expect(await rig.bridge.openRelayCount == 0)
        try await Task.sleep(for: .milliseconds(1700))
        #expect(rig.recorder.ids("r1") == [1])
    }

    @Test func aRefusedDeliveryDropsTheRelay() async throws {
        let rig = try await bridgeRig()
        defer { rig.stop() }
        rig.recorder.refuseDeliveries()
        await rig.bridge.relay(frame("r1", request(1, "initialize")), over: rig.recorder.channel)
        #expect(await awaitCondition { rig.server.requests.contains { $0.method == "DELETE" } })
        #expect(await rig.bridge.openRelayCount == 0)
        #expect(rig.recorder.failures.isEmpty)
    }

    @Test func aServerErrorWithAJSONRPCBodyIsDeliveredAndKeepsTheRelay() async throws {
        let rig = try await bridgeRig()
        defer { rig.stop() }
        await rig.bridge.relay(frame("r1", request(1, "initialize")), over: rig.recorder.channel)
        #expect(await awaitCondition { rig.recorder.ids("r1") == [1] })
        await rig.bridge.relay(frame("r1", request(2, "bad")), over: rig.recorder.channel)
        #expect(await awaitCondition { rig.recorder.ids("r1") == [1, 2] })
        #expect(rig.recorder.deliveries[1].message["error"]?["code"]?.intValue == -32602)
        #expect(await rig.bridge.openRelayCount == 1)
    }

    @Test func aRedirectIsNotFollowed() async throws {
        let rig = try await bridgeRig()
        defer { rig.stop() }
        await rig.bridge.relay(frame("r1", request(1, "redirect")), over: rig.recorder.channel)
        #expect(await awaitCondition { rig.recorder.failures.count == 1 })
        #expect(rig.server.requests.count == 1)
    }

    @Test func aRestartedServerOnANewPortIsFoundByTheNextRelay() async throws {
        let rig = try await bridgeRig()
        defer { rig.stop() }
        await rig.bridge.relay(frame("r1", request(1, "initialize")), over: rig.recorder.channel)
        #expect(await awaitCondition { rig.recorder.ids("r1") == [1] })
        let fake = FakeT3()
        let second = try await T3StubServer.start { await fake.handle($0) }
        defer { second.stop() }
        try rig.sandbox.publish(origin: second.origin)
        await rig.bridge.relay(frame("r2", request(1, "initialize")), over: rig.recorder.channel)
        #expect(await awaitCondition { rig.recorder.ids("r2") == [1] })
        #expect(second.requests.count == 1)
        #expect(rig.server.requests.count == 1)
    }

    @Test func aDroppedGatewayConnectionClosesItsRelaysAndOnlyThose() async throws {
        let rig = try await bridgeRig()
        defer { rig.stop() }
        let other = RelayRecorder()
        let doomed = rig.recorder.channel
        await rig.bridge.relay(frame("r1", request(1, "initialize")), over: doomed)
        await rig.bridge.relay(frame("r2", request(1, "initialize")), over: other.channel)
        #expect(await awaitCondition { rig.recorder.ids("r1") == [1] && other.ids("r2") == [1] })
        await rig.bridge.channelEnded(doomed.id)
        #expect(await rig.bridge.openRelayCount == 1)
        #expect(await awaitCondition { rig.server.requests.contains { $0.method == "DELETE" } })
    }

    @Test func activeServersNeedBothASavedTokenAndARunningServer() async throws {
        let rig = try await bridgeRig()
        defer { rig.stop() }
        #expect(await rig.bridge.activeServers() == [.t3code])
        try FileManager.default.removeItem(at: rig.sandbox.runtimeFile)
        #expect(await rig.bridge.activeServers().isEmpty)
        let signedOut = try await bridgeRig(token: nil)
        defer { signedOut.stop() }
        #expect(await signedOut.bridge.activeServers().isEmpty)
    }
}
