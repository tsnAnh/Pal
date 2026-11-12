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
    @Test func mapsTransportAndKitErrors() {
        #expect(KitFailure.classify(rpcError(-32601)) == .gatewayUnsupported)
        #expect(KitFailure.classify(rpcError(4409)) == .busy)
        #expect(KitFailure.classify(rpcError(5321, data: ["code": "kit_unavailable"])) == .kitUnavailable)
        #expect(KitFailure.classify(rpcError(5321, data: ["code": "kit_unsupported", "subcommand": "reload"])) == .kitUnsupported(subcommand: "reload"))
        #expect(KitFailure.classify(rpcError(5321, data: ["code": "timeout"])) == .timeout)
        #expect(KitFailure.classify(rpcError(5321, data: ["code": "request_refused", "kit_code": "request_refused"])) == .requestRefused)
        #expect(KitFailure.classify(rpcError(5321, data: ["code": "credential_missing"])) == .credentialMissing)
        #expect(KitFailure.classify(rpcError(5321, data: ["code": "credential_unreadable"])) == .credentialUnreadable)
        #expect(KitFailure.classify(rpcError(4409, data: ["code": "busy", "kit_code": "update_in_progress"])) == .busy)
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
    @Test func rotateRunsAsAJobAndShowsCredentialStateNeverAValue() async {
        let bots = ScriptedBots()
        let rotated: JSONValue = ["credential": ["rotated": true, "created_at": "2026-01-02T03:04:05Z"]]
        bots.script("host.kit.rotate", jobJSON("succeeded", report: rotated))
        bots.script("host.kit.status", ["version": "1", "credential": ["present": true, "created": false, "created_at": "2026-01-02T03:04:05Z"]])
        let kit = model(bots)
        await kit.refreshStatus()
        #expect(kit.canRotate)
        await kit.rotate()
        #expect(kit.outcome == .succeeded(.rotate, KitReport(rotated)))
        #expect(kit.credentialText == "Key replaced at 2026-01-02T03:04:05Z")
        #expect(bots.calls(to: "host.kit.rotate").first?.params == [:])
    }

    @MainActor
    @Test func credentialStatesMapToPlainText() async {
        let created = KitCredential(["present": true, "created": true, "created_at": "T"])
        #expect(created?.summary == "Credential created at T")
        #expect(KitCredential(["present": true, "created": false, "created_at": "T"])?.summary == "Credential present, created at T")
        #expect(KitCredential(["present": false])?.summary == "No credential yet")
        #expect(KitCredential(.object([:])) == nil)

        let bots = ScriptedBots()
        bots.script("host.kit.status") { _ in throw rpcError(5321, data: ["code": "credential_missing"]) }
        let kit = model(bots)
        await kit.refreshStatus()
        #expect(kit.credentialText == "Not created yet" && kit.canAct && !kit.canRotate)
        #expect(KitFailure.credentialMissing.message.contains("first Update kit creates it"))
    }

    @MainActor
    @Test func theFirstUpdateShowsTheCreatedCredential() async {
        let bots = ScriptedBots()
        bots.script("host.kit.status") { _ in throw rpcError(5321, data: ["code": "credential_missing"]) }
        let created: JSONValue = ["credential": ["present": true, "created": true, "created_at": "2026-01-02T03:04:05Z"]]
        bots.script("host.kit.update", jobJSON("succeeded", report: created))
        bots.script("host.kit.status", ["credential": ["present": true, "created": false, "created_at": "2026-01-02T03:04:05Z"]])
        let kit = model(bots)
        await kit.refreshStatus()
        await kit.update()
        #expect(kit.credentialText == "Credential created at 2026-01-02T03:04:05Z")
        #expect(kit.canRotate)
    }

    @MainActor
    @Test func busyAndRepeatedPollFailuresAreTyped() async {
        let busy = ScriptedBots()
        busy.script("host.kit.update") { _ in throw rpcError(4409, data: ["code": "busy"]) }
        let first = model(busy)
        await first.update()
        #expect(first.outcome == .failed(.update, .busy))

        let status = ScriptedBots()
        status.script("host.kit.status") { _ in throw rpcError(4409, data: ["code": "busy"]) }
        let waiting = model(status)
        await waiting.refreshStatus()
        #expect(waiting.phase == .failed(.busy) && !waiting.canAct)

        let lost = ScriptedBots()
        lost.script("host.kit.update", jobJSON("running"))
        for _ in 0..<KitModel.maxPollFailures { lost.script("host.kit.job") { _ in throw rpcError(-32000) } }
        let second = model(lost)
        await second.update()
        #expect(second.outcome == .failed(.update, .unreachable))
    }

    @MainActor
    @Test func aRefusalIsItsOwnStateAndStopsFurtherActions() async {
        let bots = ScriptedBots()
        bots.script("host.kit.status", .object(["version": "1"]))
        bots.script("host.kit.update", jobJSON("failed", error: ["code": "request_refused"]))
        let kit = model(bots)
        await kit.refreshStatus()
        #expect(kit.canAct)
        await kit.update()
        #expect(kit.outcome == .failed(.update, .requestRefused))
        #expect(kit.isRefused && !kit.canAct)
        #expect(KitFailure.requestRefused.message == "The kit on this machine is not set up for the app yet.")
        #expect(bots.calls(to: "host.kit.update").count == 1)

        let refused = ScriptedBots()
        refused.script("host.kit.status") { _ in throw rpcError(5321, data: ["code": "request_refused"]) }
        let blocked = model(refused)
        await blocked.refreshStatus()
        #expect(blocked.phase == .failed(.requestRefused) && !blocked.canAct)
    }

    @MainActor
    @Test func nextActionIsTextOnly() async {
        let bots = ScriptedBots()
        bots.script("host.kit.reload", jobJSON("succeeded", report: ["next_action": "run: restart the app"]))
        bots.script("host.kit.status", .object([:]))
        let kit = model(bots)
        await kit.reload(.routes)
        #expect(kit.outcome == .succeeded(.reload, KitReport(["next_action": "run: restart the app"])))
        #expect(bots.calls.map(\.method) == ["host.kit.reload", "host.kit.status"])
    }
}
