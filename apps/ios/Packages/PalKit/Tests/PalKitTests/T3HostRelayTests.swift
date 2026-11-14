import Foundation
import PalDevice
import PalProtocol
import PalT3Code
import PalTransport
import Synchronization
import Testing

private final class McpGateway: Sendable {
    private let calls = Mutex<[(method: String, params: JSONValue?)]>([])

    func handle(_ method: String, _ params: JSONValue?, _ connection: Int) -> FakeGateway.Reply {
        calls.withLock { $0.append((method, params)) }
        switch method {
        case "device_connectors.list":
            return .result(["device_id": "device-1234", "connectors": []])
        case "device.mcp.deliver":
            return .result(["accepted": true])
        case "device.mcp.register":
            return .result(["registered": true, "name": "t3code"])
        case "device.mcp.fail", "device.mcp.unregister":
            return .result([:])
        case "gateway.ping":
            return .result(["ok": true])
        default:
            return .failure(RPCError(code: -32601, message: "unknown_method", data: ["reason": "unknown_method"]))
        }
    }

    func params(_ method: String) -> [JSONValue] {
        calls.withLock { $0.filter { $0.method == method }.compactMap(\.params) }
    }
}

private func mcpEvent(_ type: String, _ payload: JSONValue) -> JSONValue {
    ["type": .string(type), "payload": payload]
}

private struct HostMcpRig {
    let gateway: FakeGateway
    let script: McpGateway
    let server: T3StubServer
    let sandbox: T3Sandbox
    let stack: DeviceToolStack
    let bridge: T3McpBridge

    func stop() async {
        await stack.host.stop()
        gateway.stop()
        server.stop()
        sandbox.remove()
    }
}

private func hostMcpRig(token: String? = FakeT3.goodToken) async throws -> HostMcpRig {
    let fake = FakeT3()
    let server = try await T3StubServer.start { await fake.handle($0) }
    let sandbox = try T3Sandbox()
    try sandbox.publish(origin: server.origin)
    let bridge = T3McpBridge(
        locator: sandbox.locator,
        tokens: InMemoryT3TokenStore(token.map { T3Token(access: SecretString($0), expiresAt: nil) })
    )
    let script = McpGateway()
    let gateway = try await FakeGateway.start { method, params, connection in script.handle(method, params, connection) }
    let url = gateway.url
    let device = FakeDevice()
    let stack = DeviceToolStack.make(
        connect: { try await GatewayConnection.dial(url: url, ticket: "device-test") },
        providers: DeviceProviders(calendar: device, reminders: device, contacts: device, location: device, alarms: device, home: device),
        permissions: FakePermissions(),
        consent: FakeConsent(),
        environment: DeviceToolEnvironment(deadlineMargin: .zero),
        timing: DeviceToolHostTiming(backoff: [.milliseconds(50)], pingInterval: .seconds(60), callTimeout: .seconds(5), connectWait: .seconds(5)),
        mcpRelay: bridge
    )
    await stack.host.start()
    #expect(await awaitCondition { gateway.liveConnectionCount == 1 })
    return HostMcpRig(gateway: gateway, script: script, server: server, sandbox: sandbox, stack: stack, bridge: bridge)
}

@Suite("Device host MCP relay")
struct T3HostRelayTests {
    @Test func aConnectedHostRegistersTheServerWhenSignedInAndRunning() async throws {
        let rig = try await hostMcpRig()
        #expect(await awaitCondition { rig.script.params("device.mcp.register").count == 1 })
        #expect(rig.script.params("device.mcp.register")[0]["server"]?.stringValue == "t3code")
        await rig.stop()
    }

    @Test func aSignedOutHostRegistersNothing() async throws {
        let rig = try await hostMcpRig(token: nil)
        try await Task.sleep(for: .milliseconds(300))
        #expect(rig.script.params("device.mcp.register").isEmpty)
        await rig.stop()
    }

    @Test func frameEventsReachT3AndRepliesComeBackAsDeliverCalls() async throws {
        let rig = try await hostMcpRig()
        rig.gateway.push(mcpEvent("device.mcp.frame", [
            "relay_id": "relay-1", "server": "t3code",
            "message": ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [:]],
        ]))
        #expect(await awaitCondition { rig.script.params("device.mcp.deliver").count == 1 })
        rig.gateway.push(mcpEvent("device.mcp.frame", [
            "relay_id": "relay-1", "server": "t3code", "message": ["jsonrpc": "2.0", "id": 2, "method": "tools/list"],
        ]))
        #expect(await awaitCondition { rig.script.params("device.mcp.deliver").count == 2 })
        let deliveries = rig.script.params("device.mcp.deliver")
        #expect(deliveries.allSatisfy { $0["relay_id"]?.stringValue == "relay-1" })
        #expect(deliveries[1]["message"]?["result"]?["tools"]?[0]?["name"]?.stringValue == "t3_thread_wait")
        let text = String(describing: deliveries)
        #expect(!text.contains(FakeT3.goodToken))
        await rig.stop()
    }

    @Test func aRejectedTokenComesBackAsAFailCall() async throws {
        let rig = try await hostMcpRig(token: "stale")
        rig.gateway.push(mcpEvent("device.mcp.frame", [
            "relay_id": "relay-9", "server": "t3code", "message": ["jsonrpc": "2.0", "id": 1, "method": "initialize"],
        ]))
        #expect(await awaitCondition { rig.script.params("device.mcp.fail").count == 1 })
        let fail = rig.script.params("device.mcp.fail")[0]
        #expect(fail["relay_id"]?.stringValue == "relay-9")
        #expect(fail["code"]?.stringValue == "auth_required")
        #expect(fail["message"]?.stringValue == "Sign in to T3 Code again")
        await rig.stop()
    }

    @Test func closeEventsEndTheRelayAndDeleteTheSession() async throws {
        let rig = try await hostMcpRig()
        rig.gateway.push(mcpEvent("device.mcp.frame", [
            "relay_id": "relay-2", "server": "t3code", "message": ["jsonrpc": "2.0", "id": 1, "method": "initialize"],
        ]))
        #expect(await awaitCondition { rig.script.params("device.mcp.deliver").count == 1 })
        rig.gateway.push(mcpEvent("device.mcp.close", ["relay_id": "relay-2", "reason": "client_closed"]))
        #expect(await awaitCondition { rig.server.requests.contains { $0.method == "DELETE" } })
        #expect(await rig.bridge.openRelayCount == 0)
        await rig.stop()
    }

    @Test func aDroppedConnectionClosesItsRelaysAndTheReconnectRegistersAgain() async throws {
        let rig = try await hostMcpRig()
        rig.gateway.push(mcpEvent("device.mcp.frame", [
            "relay_id": "relay-3", "server": "t3code", "message": ["jsonrpc": "2.0", "id": 1, "method": "initialize"],
        ]))
        #expect(await awaitCondition { rig.script.params("device.mcp.deliver").count == 1 })
        rig.gateway.dropAll()
        #expect(await awaitCondition { rig.script.params("device.mcp.register").count == 2 })
        #expect(await rig.bridge.openRelayCount == 0)
        await rig.stop()
    }

    @Test func theHostRegistersAndUnregistersOnDemand() async throws {
        let rig = try await hostMcpRig(token: nil)
        #expect(try await rig.stack.host.registerMcp(.t3code))
        try await rig.stack.host.unregisterMcp(.t3code)
        #expect(rig.script.params("device.mcp.register").count == 1)
        #expect(rig.script.params("device.mcp.unregister").first?["server"]?.stringValue == "t3code")
        await rig.stop()
    }
}

@Suite("Device MCP wire")
struct DeviceMcpWireTests {
    @Test func parsesFramesAndCloses() throws {
        let frame = try #require(DeviceMcpFrame(event: GatewayEvent(type: "device.mcp.frame", payload: [
            "relay_id": "r", "server": "t3code", "message": ["jsonrpc": "2.0"],
        ])))
        #expect(frame.relayID == "r")
        #expect(frame.server == .t3code)
        let close = try #require(DeviceMcpClose(event: GatewayEvent(type: "device.mcp.close", payload: ["relay_id": "r", "reason": "timeout"])))
        #expect(close.reason == .timeout)
        #expect(DeviceMcpClose(event: GatewayEvent(type: "device.mcp.close", payload: ["relay_id": "r", "reason": "weird"]))?.reason == .clientClosed)
    }

    @Test func ignoresFramesForUnknownServersOrWithoutAnId() {
        #expect(DeviceMcpFrame(event: GatewayEvent(type: "device.mcp.frame", payload: ["relay_id": "r", "server": "other", "message": [:]])) == nil)
        #expect(DeviceMcpFrame(event: GatewayEvent(type: "device.mcp.frame", payload: ["server": "t3code", "message": [:]])) == nil)
        #expect(DeviceMcpFrame(event: GatewayEvent(type: "device.mcp.frame", payload: ["relay_id": "", "server": "t3code", "message": [:]])) == nil)
        #expect(DeviceMcpFrame(event: GatewayEvent(type: "device.tool.request", payload: ["relay_id": "r", "server": "t3code", "message": [:]])) == nil)
    }

    @Test func failParamsCarryTheWireCodesAndShortText() {
        let params = DeviceMcpWire.failParams(relayID: "r", code: .authRequired, message: String(repeating: "m", count: 500))
        #expect(params["code"]?.stringValue == "auth_required")
        #expect(params["message"]?.stringValue?.count == DeviceMcpLimits.maximumFailMessage)
        #expect(DeviceMcpFailCode.unreachable.rawValue == "unreachable")
        #expect(DeviceMcpFailCode.closed.rawValue == "closed")
        #expect(DeviceMcpCloseReason.clientClosed.rawValue == "client_closed")
        #expect(DeviceMcpCloseReason.unregistered.rawValue == "unregistered")
        #expect(DeviceMcpLimits.maximumMessageBytes == 4_194_304)
    }
}
