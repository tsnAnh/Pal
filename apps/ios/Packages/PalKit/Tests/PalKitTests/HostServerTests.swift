import Foundation
import Testing

@testable import PalBotProfile
@testable import PalProtocol
@testable import PalTransport

private let methodNotFound = GatewayTransportError.rpc(RPCError(code: -32601, message: "method not found"))

private func logsJSON(_ lines: [String], hasMore: Bool = false, truncated: Bool = false, available: Bool = true) -> JSONValue {
    ["name": "gateway", "lines": .array(lines.map { .string($0) }), "has_more": .bool(hasMore), "truncated": .bool(truncated), "available": .bool(available)]
}

@MainActor
private func model(_ bots: ScriptedBots) -> HostServerModel {
    HostServerModel(client: HostServerClient(gateway: bots.gateway))
}

@Suite("Host server")
struct HostServerTests {
    @Test("health decodes a full answer")
    func fullHealth() async throws {
        let bots = ScriptedBots()
        bots.script(
            "host.health",
            [
                "version": "2026.11+3", "commit": "abc1234", "python_version": "3.14.0", "platform": "Darwin arm64",
                "disk_free_bytes": .int(5_000_000_000), "disk_total_bytes": .int(10_000_000_000),
                "host_uptime_seconds": .int(90_000), "profile_count": .int(3), "running_gateway_count": .int(2),
                "doctor_ran": true,
                "problems": [["severity": "error", "message": "State database is unreadable"], ["severity": "warning", "message": "Cron store is not writable"]],
            ])
        let health = try await HostServerClient(gateway: bots.gateway).health()
        #expect(health.version == "2026.11+3" && health.commit == "abc1234")
        #expect(health.diskFreeBytes == 5_000_000_000 && health.profileCount == 3 && health.runningGatewayCount == 2)
        #expect(health.problems.map(\.severity) == [.error, .warning])
        #expect(health.doctorRan)
    }

    @Test("health with every field missing decodes to unknowns, not a failure")
    func sparseHealth() async throws {
        let bots = ScriptedBots()
        bots.script("host.health", ["doctor_ran": false, "problems": []])
        let health = try await HostServerClient(gateway: bots.gateway).health()
        #expect(health.version == nil && health.diskFreeBytes == nil && health.hostUptimeSeconds == nil)
        #expect(health.profileCount == nil && health.runningGatewayCount == nil)
        #expect(!health.doctorRan && health.problems.isEmpty)
    }

    @Test("an unknown severity reads as a warning and an empty message is dropped")
    func oddProblems() async throws {
        let bots = ScriptedBots()
        bots.script("host.health", ["doctor_ran": true, "problems": [["severity": "fatal", "message": "x"], ["severity": "error", "message": "  "]]])
        let health = try await HostServerClient(gateway: bots.gateway).health()
        #expect(health.problems == [HostProblem(severity: .warning, message: "x")])
    }

    @MainActor
    @Test("an older gateway shows unsupported for health and logs")
    func olderGateway() async {
        let bots = ScriptedBots()
        bots.script("host.health") { _ in throw methodNotFound }
        bots.script("host.logs.tail") { _ in throw methodNotFound }
        let model = model(bots)
        await model.refresh()
        #expect(model.health == .unsupported)
        #expect(model.logState == .unsupported)
    }

    @MainActor
    @Test("a transport failure is failed, and a later success replaces it")
    func failureThenSuccess() async {
        let bots = ScriptedBots()
        bots.script("host.health") { _ in throw GatewayTransportError.closed(.normal) }
        bots.script("host.health", ["doctor_ran": true, "problems": []])
        let model = model(bots)
        await model.loadHealth()
        #expect(model.health == .failed)
        await model.loadHealth()
        #expect(model.health.value?.doctorRan == true)
    }

    @MainActor
    @Test("a refresh that fails keeps the lines already shown")
    func refreshKeepsLines() async {
        let bots = ScriptedBots()
        bots.script("host.logs.tail", logsJSON(["a", "b"]))
        bots.script("host.logs.tail") { _ in throw GatewayTransportError.timedOut }
        let model = model(bots)
        await model.loadLogs()
        await model.loadLogs()
        #expect(model.logLines == ["a", "b"])
        #expect(model.logState.value != nil)
    }

    @MainActor
    @Test("older pages are requested by line count and prepended")
    func paging() async {
        let bots = ScriptedBots()
        bots.script("host.logs.tail", logsJSON(["c", "d"], hasMore: true))
        bots.script("host.logs.tail", logsJSON(["a", "b"], hasMore: false))
        let model = model(bots)
        await model.loadLogs()
        #expect(model.hasOlderLines)
        await model.loadOlder()
        #expect(model.logText == "a\nb\nc\nd")
        #expect(!model.hasOlderLines)
        let calls = bots.calls(to: "host.logs.tail")
        #expect(calls[0].params == ["name": "gateway", "lines": .int(HostServerModel.pageSize), "skip": .int(0)])
        #expect(calls[1].params["skip"] == .int(2))
    }

    @MainActor
    @Test("switching log starts from an empty tail and asks for that log")
    func switchingLog() async {
        let bots = ScriptedBots()
        bots.script("host.logs.tail", logsJSON(["g"]))
        bots.script("host.logs.tail", logsJSON(["e"]))
        let model = model(bots)
        await model.loadLogs()
        await model.selectLog(.errors)
        #expect(model.logLines == ["e"])
        #expect(bots.calls(to: "host.logs.tail").last?.params["name"] == "errors")
    }

    @Test("a log that does not exist yet is an empty, available-false page")
    func missingLog() async throws {
        let bots = ScriptedBots()
        bots.script("host.logs.tail", logsJSON([], available: false))
        let page = try await HostServerClient(gateway: bots.gateway).logs(.gateway, lines: 10, skip: 0)
        #expect(page.lines.isEmpty && !page.available)
    }
}
