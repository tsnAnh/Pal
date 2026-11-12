import Foundation
import Testing

@testable import PalBotProfile
@testable import PalProtocol
@testable import PalTransport

private func rpcError(_ code: Int, data: JSONValue? = nil) -> GatewayTransportError {
    .rpc(RPCError(code: code, message: "x", data: data))
}

private func jobJSON(_ state: String, id: String = "j1", report: JSONValue? = nil, error: JSONValue? = nil) -> JSONValue {
    var object: [String: JSONValue] = ["job_id": .string(id), "operation": "update", "state": .string(state)]
    if let report { object["report"] = report }
    if let error { object["error"] = error }
    return .object(object)
}

@MainActor
private func model(_ bots: ScriptedBots) -> KitModel {
    KitModel(client: KitClient(gateway: bots.gateway), sleep: { _ in })
}

@Suite struct HostKitTests {
    @Test(arguments: ["octo/hello", "a/b.c_d-e", "A1/repo.name"])
    func acceptsOwnerRepo(_ value: String) {
        #expect(KitRepo.isValid(value))
    }

    @Test(arguments: [
        "", "owner", "owner/", "/repo", "a/b/c", "../etc/passwd", "a/../b", "owner/repo name", "--foo", "-x/y",
        "owner/repo\n--json", "o;id/r", "o/r$(id)", "-owner/repo", "o/..", String(repeating: "a", count: 40) + "/r",
    ])
    func rejectsEverythingElse(_ value: String) {
        #expect(!KitRepo.isValid(value))
    }

    @Test func mapsTransportAndKitErrors() {
        #expect(KitFailure.classify(rpcError(-32601)) == .gatewayUnsupported)
        #expect(KitFailure.classify(rpcError(4409)) == .busy)
        #expect(KitFailure.classify(rpcError(4101)) == .invalidRepo)
        #expect(KitFailure.classify(rpcError(5321, data: ["code": "kit_unavailable"])) == .kitUnavailable)
        #expect(KitFailure.classify(rpcError(5321, data: ["code": "kit_unsupported", "subcommand": "reload"])) == .kitUnsupported(subcommand: "reload"))
        #expect(KitFailure.classify(rpcError(5321, data: ["code": "timeout"])) == .timeout)
        #expect(KitFailure.classify(rpcError(5321, data: ["code": "failed", "tail": "boom"])) == .failed(tail: "boom"))
        #expect(KitFailure.classify(rpcError(5321, data: ["code": "invalid_output", "tail": "x"])) == .invalidOutput(tail: "x"))
        #expect(KitFailure.classify(GatewayTransportError.timedOut) == .unreachable)
    }

    @MainActor
    @Test func statusLoadsVersionAndMapsOlderGateway() async {
        let bots = ScriptedBots()
        bots.script("host.kit.status", ["version": "1.2.3", "status": "ready"])
        let kit = model(bots)
        await kit.refreshStatus()
        #expect(kit.report?.version == "1.2.3" && kit.canAct)

        let old = ScriptedBots()
        old.script("host.kit.status") { _ in throw rpcError(-32601) }
        let older = model(old)
        await older.refreshStatus()
        #expect(older.phase == .failed(.gatewayUnsupported) && !older.canAct)
    }

    @MainActor
    @Test func updatePollsUntilTheJobSucceedsThenRereadsStatus() async {
        let bots = ScriptedBots()
        bots.script("host.kit.update", jobJSON("running"))
        bots.script("host.kit.job", jobJSON("running"))
        bots.script("host.kit.job", jobJSON("succeeded", report: ["version": "2.0.0"]))
        bots.script("host.kit.status", ["version": "2.0.0"])
        let kit = model(bots)
        await kit.update()
        #expect(kit.outcome == .succeeded(.update, KitReport(["version": "2.0.0"])))
        #expect(kit.running == nil && kit.report?.version == "2.0.0")
        #expect(bots.calls(to: "host.kit.job").count == 2)
    }

    @MainActor
    @Test func aFailedJobCarriesItsTypedError() async {
        let bots = ScriptedBots()
        bots.script("host.kit.reload", jobJSON("failed", error: ["code": "kit_unsupported", "subcommand": "reload"]))
        let kit = model(bots)
        await kit.reload(.routes)
        #expect(kit.outcome == .failed(.reload, .kitUnsupported(subcommand: "reload")))
        #expect(bots.calls(to: "host.kit.reload").first?.params == ["target": "routes"])
    }

    @MainActor
    @Test func addProjectRefusesBadInputLocallyAndSendsTheTrimmedRepo() async {
        let bots = ScriptedBots()
        bots.script("host.kit.add_project", jobJSON("succeeded", report: .object([:])))
        bots.script("host.kit.status", .object([:]))
        let kit = model(bots)
        await kit.addProject("--foo")
        #expect(kit.outcome == .failed(.addProject, .invalidRepo))
        #expect(bots.calls(to: "host.kit.add_project").isEmpty)
        await kit.addProject("  octo/hello \n")
        #expect(kit.outcome == .succeeded(.addProject, KitReport(.object([:]))))
        #expect(bots.calls(to: "host.kit.add_project").first?.params == ["repo": "octo/hello"])
    }

    @MainActor
    @Test func busyAndRepeatedPollFailuresAreTyped() async {
        let busy = ScriptedBots()
        busy.script("host.kit.refresh") { _ in throw rpcError(4409, data: ["code": "busy"]) }
        let first = model(busy)
        await first.refresh()
        #expect(first.outcome == .failed(.refresh, .busy))

        let lost = ScriptedBots()
        lost.script("host.kit.refresh", jobJSON("running"))
        for _ in 0..<KitModel.maxPollFailures { lost.script("host.kit.job") { _ in throw rpcError(-32000) } }
        let second = model(lost)
        await second.refresh()
        #expect(second.outcome == .failed(.refresh, .unreachable))
    }
}
