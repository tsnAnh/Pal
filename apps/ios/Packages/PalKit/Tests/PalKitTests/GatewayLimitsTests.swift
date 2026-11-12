import Foundation
import Testing

@testable import PalBotProfile
@testable import PalProtocol
@testable import PalTransport

private func row(_ key: String, _ value: JSONValue?, source: String? = "config", clamped: Bool? = false) -> JSONValue {
    var object: [String: JSONValue] = ["key": .string(key)]
    if let value { object["value"] = value }
    if let source { object["source"] = .string(source) }
    if let clamped { object["clamped"] = .bool(clamped) }
    return .object(object)
}

@Suite("Limits in effect")
struct GatewayLimitsTests {
    @Test("a configured, a standard and a capped value read plainly")
    func decoding() throws {
        let hops = try #require(GatewayLimit(row("gateway.bot_loop_guard.max_hops", .int(50), clamped: true)))
        #expect(hops.title == "Messages per bot exchange")
        #expect(hops.value == "50")
        #expect(hops.detail == "Set in your settings, Capped at the allowed maximum")
        let window = try #require(GatewayLimit(row("gateway.bot_loop_guard.window_seconds", .double(300), source: "default")))
        #expect(window.value == "300 s")
        #expect(window.detail == "Standard value")
        let guardFlag = try #require(GatewayLimit(row("gateway.bot_loop_guard.enabled", .bool(true), source: "default")))
        #expect(guardFlag.value == "On")
    }

    @Test("missing or unreadable fields become unknown, never a guess")
    func missingFields() throws {
        let bare = try #require(GatewayLimit(["key": "gateway.bot_loop_guard.max_hops"]))
        #expect(bare.value == "Unknown")
        #expect(bare.detail == nil)
        #expect(try #require(GatewayLimit(row("gateway.bot_loop_guard.max_hops", .string("ten")))).value == "Unknown")
        #expect(GatewayLimit(["value": 3]) == nil)
        #expect(GatewayLimit(JSONValue.null) == nil)
    }

    @Test("method-not-found is the unsupported state")
    func classification() {
        #expect(GatewayLimitsFailure.classify(GatewayTransportError.rpc(RPCError(code: -32601, message: "x"))) == .unsupported)
        #expect(GatewayLimitsFailure.classify(GatewayTransportError.rpc(RPCError(code: 4403, message: "x"))) == .unavailable)
    }

    @Test("the client lists the gateway's rows and skips ones it cannot read")
    func client() async throws {
        let bots = ScriptedBots()
        bots.script("gateway.guards.status", ["guards": .array([row("gateway.bot_loop_guard.max_hops", .int(10)), ["nope": true]])])
        let limits = try await GatewayLimitsClient(gateway: bots.gateway).limits()
        #expect(limits.map(\.id) == ["gateway.bot_loop_guard.max_hops"])
    }

    @Test("an older gateway and a broken reply are told apart")
    func failures() async {
        let older = ScriptedBots()
        older.script("gateway.guards.status") { _ in throw GatewayTransportError.rpc(RPCError(code: -32601, message: "x")) }
        await #expect(throws: GatewayLimitsFailure.unsupported) { try await GatewayLimitsClient(gateway: older.gateway).limits() }
        let broken = ScriptedBots()
        broken.script("gateway.guards.status", ["unexpected": true])
        await #expect(throws: GatewayLimitsFailure.unavailable) { try await GatewayLimitsClient(gateway: broken.gateway).limits() }
    }
}
