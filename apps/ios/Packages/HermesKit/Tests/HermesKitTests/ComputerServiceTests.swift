import Foundation
import HermesBotProfile
import HermesProtocol
import HermesTransport
import Testing

private func status(
    supported: Bool = true,
    installed: Bool = true,
    running: Bool = true,
    blocker: String? = nil,
    holder: String = "agent",
    ask: String = "",
    askAt: Double = 0
) -> JSONValue {
    var wire: [String: JSONValue] = [
        "supported": .bool(supported),
        "installed": .bool(installed),
        "running": .bool(running),
        "lease": ["holder": .string(holder), "ask": .string(ask), "ask_at": .double(askAt), "viewer_hash": .null],
    ]
    if let blocker { wire["blocker"] = .string(blocker) }
    return .object(wire)
}

private func observation(viewerID: String = "viewer-minted", holder: String = "agent", ask: String = "", askAt: Double = 0) -> JSONValue {
    var wire = status(holder: holder, ask: ask, askAt: askAt).objectValue ?? [:]
    wire["ticket"] = "ticket-1"
    wire["path"] = "/api/display/ws"
    wire["viewer_id"] = .string(viewerID)
    return .object(wire)
}

private func rpcRefusal(code: String) -> GatewayTransportError {
    .rpc(RPCError(code: 5300, message: "refused", data: ["reason": "refused", "code": .string(code)]))
}

@Suite("Bot computer")
struct ComputerServiceTests {
    @Test("an unsupported host answers unavailable and never starts or observes")
    func unsupportedHost() async {
        let bots = ScriptedBots()
        bots.script("display.status", status(supported: false, installed: false, running: false))
        await #expect(throws: ComputerFailure.unavailable) { try await ComputerService(gateway: bots.gateway).prepare(for: "cho-ua") }
        #expect(bots.calls.map(\.method) == ["display.status"])
    }

    @Test("a host without the desktop packages answers not set up")
    func notInstalled() async {
        let bots = ScriptedBots()
        bots.script("display.status", status(installed: false, running: false))
        await #expect(throws: ComputerFailure.notSetUp) { try await ComputerService(gateway: bots.gateway).prepare(for: "cho-ua") }
        #expect(bots.calls(to: "display.start").isEmpty)
    }

    @Test("a stopped computer that the host cannot afford to start answers low memory without starting it")
    func blocked() async {
        let bots = ScriptedBots()
        bots.script("display.status", status(running: false, blocker: "needs 1.5 GB free"))
        await #expect(throws: ComputerFailure.lowMemory) { try await ComputerService(gateway: bots.gateway).prepare(for: "cho-ua") }
        #expect(bots.calls(to: "display.start").isEmpty)
    }

    @Test("a stopped computer is started, then observed for this bot only")
    func startsThenObserves() async throws {
        let bots = ScriptedBots()
        bots.script("display.status", status(running: false))
        bots.script("display.start", status(running: true))
        bots.script("display.observe", observation())
        let result = try await ComputerService(gateway: bots.gateway).prepare(for: "cho-ua")
        #expect(bots.calls.map(\.method) == ["display.status", "display.start", "display.observe"])
        #expect(bots.calls.allSatisfy { $0.params["profile"] == "cho-ua" })
        #expect(result.ticket == "ticket-1")
        #expect(result.path == "/api/display/ws")
        #expect(result.viewerID == "viewer-minted")
        #expect(result.lease.humanHolds == false)
    }

    @Test("a running computer is observed without a start, and a reconnect presents the earlier viewer id")
    func observesRunning() async throws {
        let bots = ScriptedBots()
        bots.script("display.status", status())
        bots.script("display.observe", observation())
        _ = try await ComputerService(gateway: bots.gateway).prepare(for: "default", viewerID: "viewer-minted")
        #expect(bots.calls(to: "display.start").isEmpty)
        #expect(bots.calls(to: "display.observe").first?.params["viewer_id"] == "viewer-minted")
    }

    @Test("a pending ask from the bot is carried so the screen opens in control")
    func pendingAsk() async throws {
        let bots = ScriptedBots()
        bots.script("display.status", status())
        bots.script("display.observe", observation(ask: "sign in to the shared account", askAt: 1234.5))
        let result = try await ComputerService(gateway: bots.gateway).prepare(for: "default")
        #expect(result.lease.ask == "sign in to the shared account")
        #expect(result.lease.askAt == 1234.5)
    }

    @Test("an empty ask is no ask")
    func emptyAsk() async throws {
        let bots = ScriptedBots()
        bots.script("display.status", status())
        bots.script("display.observe", observation())
        let result = try await ComputerService(gateway: bots.gateway).prepare(for: "default")
        #expect(result.lease.ask == nil)
        #expect(result.lease.askAt == nil)
    }

    @Test("taking control names the viewer id minted for this connection")
    func takeControl() async throws {
        let bots = ScriptedBots()
        bots.script("display.lease.acquire", ["lease": ["holder": "human", "ask": "", "ask_at": 0.0]])
        let lease = try await ComputerService(gateway: bots.gateway).takeControl(for: "cho-ua", viewerID: "viewer-minted")
        let call = try #require(bots.calls(to: "display.lease.acquire").first)
        #expect(call.params["viewer_id"] == "viewer-minted")
        #expect(call.params["profile"] == "cho-ua")
        #expect(lease.humanHolds)
    }

    @Test("a viewer id the connection no longer knows reads as a stale viewer")
    func staleViewer() async {
        let bots = ScriptedBots()
        bots.script("display.lease.acquire") { _ in throw rpcRefusal(code: "viewer_mismatch") }
        await #expect(throws: ComputerFailure.staleViewer) {
            try await ComputerService(gateway: bots.gateway).takeControl(for: "cho-ua", viewerID: "old")
        }
    }

    @Test("a read-only grant reads as not allowed")
    func notAllowed() async {
        let bots = ScriptedBots()
        bots.script("display.lease.acquire") { _ in throw GatewayTransportError.rpc(RPCError(code: 4001, message: "permission_denied", data: ["reason": "permission_denied"])) }
        await #expect(throws: ComputerFailure.notAllowed) {
            try await ComputerService(gateway: bots.gateway).takeControl(for: "cho-ua", viewerID: "v")
        }
    }

    @Test("handing back releases the lease, then ends the ask the card showed")
    func handBackWithAsk() async throws {
        let bots = ScriptedBots()
        bots.script("display.lease.release", ["lease": ["holder": "agent", "ask": "login", "ask_at": 9.0]])
        bots.script("display.lease.resolve", ["lease": ["holder": "agent", "ask": "", "ask_at": 0.0]])
        let lease = try await ComputerService(gateway: bots.gateway).handBack(for: "cho-ua", viewerID: "v", resolvingAskAt: 9.0)
        #expect(bots.calls.map(\.method) == ["display.lease.release", "display.lease.resolve"])
        #expect(bots.calls(to: "display.lease.release").first?.params["viewer_id"] == "v")
        #expect(bots.calls(to: "display.lease.resolve").first?.params["ask_at"] == .double(9.0))
        #expect(lease.ask == nil)
    }

    @Test("handing back with no ask only releases")
    func handBackWithoutAsk() async throws {
        let bots = ScriptedBots()
        bots.script("display.lease.release", ["lease": ["holder": "agent", "ask": "", "ask_at": 0.0]])
        _ = try await ComputerService(gateway: bots.gateway).handBack(for: "cho-ua", viewerID: "v", resolvingAskAt: nil)
        #expect(bots.calls.map(\.method) == ["display.lease.release"])
    }

    @Test("a release the gateway refuses is not followed by resolving the ask")
    func releaseRefused() async {
        let bots = ScriptedBots()
        bots.script("display.lease.release") { _ in throw rpcRefusal(code: "viewer_mismatch") }
        await #expect(throws: ComputerFailure.staleViewer) {
            try await ComputerService(gateway: bots.gateway).handBack(for: "cho-ua", viewerID: "v", resolvingAskAt: 9.0)
        }
        #expect(bots.calls(to: "display.lease.resolve").isEmpty)
    }

    @Test("control is mine only when the human holder's hash is my viewer id's hash")
    func heldBy() async throws {
        let bots = ScriptedBots()
        let hash = "d4348d76f869"
        bots.script("display.lease.acquire", ["lease": ["holder": "human", "viewer_hash": .string(hash), "ask": "", "ask_at": 0.0]])
        let lease = try await ComputerService(gateway: bots.gateway).takeControl(for: "cho-ua", viewerID: "viewer-minted")
        #expect(lease.humanHolds)
        #expect(lease.isHeld(by: "someone-else") == false)
        #expect(lease.isHeld(by: "viewer-minted"))
    }
}
