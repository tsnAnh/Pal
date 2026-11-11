import Foundation
import Synchronization
import Testing

@testable import PalBotProfile
@testable import PalProtocol
@testable import PalTransport

@Suite("Gateway service")
struct GatewayServiceTests {
    private func status(
        _ state: String = "running", instance: String? = "gen-1", activeRuns: Int = 0, startedAt: Double? = 1_000
    ) -> JSONValue {
        var object: [String: JSONValue] = [
            "backend": "systemd", "state": .string(state), "installed": true, "running": true,
            "restart_needed": false, "active_runs": .int(activeRuns),
        ]
        if let instance { object["instance"] = .string(instance) }
        if let startedAt { object["started_at"] = .double(startedAt) }
        return .object(object)
    }

    private func action(_ outcome: String, reason: String? = nil, status: JSONValue) -> JSONValue {
        var object: [String: JSONValue] = ["outcome": .string(outcome), "status": status]
        if let reason { object["reason"] = .string(reason) }
        return .object(object)
    }

    private func client(_ bots: ScriptedBots) -> GatewayServiceClient {
        GatewayServiceClient(gateway: bots.gateway, pollInterval: .zero, pollLimit: 4, sleep: { _ in })
    }

    @Test("status maps every service state")
    func states() async throws {
        let expected: [(String, GatewayServiceState)] = [
            ("running", .running), ("stopped", .stopped), ("not_installed", .notInstalled),
            ("restart_needed", .restartNeeded), ("unsupported", .unsupported), ("from_the_future", .unknown),
        ]
        for (wire, state) in expected {
            let bots = ScriptedBots()
            bots.script("gateway.service.status", status(wire))
            let info = try await client(bots).status()
            #expect(info.state == state)
            #expect(info.startedAt == Date(timeIntervalSince1970: 1_000))
        }
    }

    @Test("restart succeeds only once a different instance is running")
    func restartProof() async {
        let bots = ScriptedBots()
        bots.script("gateway.service.status", status(instance: "gen-1"))
        bots.script("gateway.service.restart", action("started", status: status(instance: "gen-1")))
        bots.script("gateway.service.status", status(instance: "gen-1"))
        bots.script("gateway.service.status") { _ in throw GatewayTransportError.closed(.normal) }
        bots.script("gateway.service.status", status(instance: "gen-2", startedAt: 2_000))
        let outcome = await client(bots).restart()
        guard case .done(let info) = outcome else { Issue.record("expected done, got \(outcome)"); return }
        #expect(info.instance == "gen-2")
        #expect(info.startedAt == Date(timeIntervalSince1970: 2_000))
        #expect(bots.calls(to: "gateway.service.restart").first?.params == [:])
    }

    @Test("a restart that never comes back is pending, not a failure")
    func restartPending() async {
        let bots = ScriptedBots()
        bots.script("gateway.service.status", status(instance: "gen-1"))
        bots.script("gateway.service.restart", action("started", status: status(instance: "gen-1")))
        let outcome = await client(bots).restart()
        guard case .pending = outcome else { Issue.record("expected pending, got \(outcome)"); return }
    }

    @Test("a connection that drops during the restart request keeps waiting for the new instance")
    func dropMidRequest() async {
        let bots = ScriptedBots()
        bots.script("gateway.service.status", status(instance: "gen-1"))
        bots.script("gateway.service.restart") { _ in throw GatewayTransportError.closed(.normal) }
        bots.script("gateway.service.status", status(instance: "gen-2"))
        let outcome = await client(bots).restart()
        guard case .done(let info) = outcome else { Issue.record("expected done, got \(outcome)"); return }
        #expect(info.instance == "gen-2")
    }

    @Test("busy, refused and unsupported carry the gateway's plain reason and poll nothing")
    func refusals() async {
        for (wire, reason) in [("busy", "Hermes can't restart while a chat is running."), ("refused", "Only the main connection can do that."), ("unsupported", "No service manager.")] {
            let bots = ScriptedBots()
            bots.script("gateway.service.status", status())
            bots.script("gateway.service.restart", action(wire, reason: reason, status: status(activeRuns: 1)))
            let outcome = await client(bots).restart()
            switch (wire, outcome) {
            case ("busy", .busy(let text)), ("refused", .refused(let text)), ("unsupported", .unsupported(let text)):
                #expect(text == reason)
            default:
                Issue.record("\(wire) mapped to \(outcome)")
            }
            #expect(bots.calls(to: "gateway.service.status").count == 1)
        }
    }

    @Test("force is sent only when asked for")
    func force() async {
        let bots = ScriptedBots()
        bots.script("gateway.service.status", status())
        bots.script("gateway.service.restart", action("busy", reason: "x", status: status()))
        _ = await client(bots).restart(force: true)
        #expect(bots.calls(to: "gateway.service.restart").first?.params == ["force": .bool(true)])
    }

    @Test("a rejected restart request is a failure")
    func rejected() async {
        let bots = ScriptedBots()
        bots.script("gateway.service.status", status())
        bots.script("gateway.service.restart") { _ in throw GatewayTransportError.rpc(RPCError(code: 5201, message: "Could not restart Hermes")) }
        let outcome = await client(bots).restart()
        #expect(outcome == .failed(GatewayServiceClient.couldNotRestart))
    }

    @Test("install reports installed, unsupported and failed")
    func install() async {
        let installed = ScriptedBots()
        installed.script("gateway.service.install", action("installed", status: status("stopped")))
        guard case .done(let info) = await client(installed).install() else { Issue.record("expected done"); return }
        #expect(info.state == .stopped)

        let unsupported = ScriptedBots()
        unsupported.script("gateway.service.install", action("unsupported", reason: "No service manager.", status: status("unsupported")))
        #expect(await client(unsupported).install() == .unsupported("No service manager."))

        let failed = ScriptedBots()
        failed.script("gateway.service.install", action("failed", reason: "Hermes couldn't install the service on this computer.", status: status("not_installed")))
        #expect(await client(failed).install() == .failed("Hermes couldn't install the service on this computer."))
    }

    @Test("state helpers say what the app may offer")
    func offers() throws {
        let stopped = GatewayServiceInfo(state: .stopped, activeRuns: 0, instance: nil, startedAt: nil, reason: nil)
        #expect(stopped.canRestart && !stopped.canInstall)
        let missing = GatewayServiceInfo(state: .notInstalled, activeRuns: 0, instance: nil, startedAt: nil, reason: nil)
        #expect(missing.canInstall && !missing.canRestart)
        let none = GatewayServiceInfo(state: .unsupported, activeRuns: 0, instance: nil, startedAt: nil, reason: "x")
        #expect(!none.canInstall && !none.canRestart)
    }
}
