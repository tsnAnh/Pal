import Foundation
import Synchronization
import Testing

@testable import PalBotProfile
@testable import PalProtocol
@testable import PalTransport

@Suite("Host update")
struct HostUpdateTests {
    private func checkReply(
        status: String = "update_available", behind: Int? = 3, error: String? = nil,
        blockers: [String] = [], link: String? = "https://github.com/acme/pal/releases"
    ) -> JSONValue {
        var object: [String: JSONValue] = [
            "version": "0.9.0+3", "status": .string(status), "active_runs": .int(blockers.contains("turn_running") ? 1 : 0),
            "blockers": .array(blockers.map(JSONValue.string)),
        ]
        if let behind { object["commits_behind"] = .int(behind) }
        if let error { object["error"] = .string(error) }
        if let link { object["release_notes_url"] = .string(link) }
        return .object(object)
    }

    private func state(
        _ state: String, phase: String? = nil, tail: [String] = [], failure: String? = nil,
        leftBehind: String? = nil, version: String = "0.9.0+3"
    ) -> JSONValue {
        var object: [String: JSONValue] = [
            "state": .string(state), "tail": .array(tail.map(JSONValue.string)), "version": .string(version),
        ]
        if let phase { object["phase"] = .string(phase) }
        if let failure { object["failure"] = .string(failure) }
        if let leftBehind { object["left_behind"] = .string(leftBehind) }
        return .object(object)
    }

    private func client(_ bots: ScriptedBots, downLimit: Int = 4, runLimit: Int = 20) -> HostUpdateClient {
        HostUpdateClient(gateway: bots.gateway, pollInterval: .zero, downLimit: downLimit, runLimit: runLimit, sleep: { _ in })
    }

    private func gatewayDown(_ bots: ScriptedBots) {
        bots.script("host.update.status") { _ in throw GatewayTransportError.closed(.normal) }
    }

    @Test("check decodes the verdict, link and blockers")
    func checkDecoding() async throws {
        let bots = ScriptedBots()
        bots.script("host.update.check", checkReply(blockers: ["turn_running"]))
        let check = try await client(bots).check()
        #expect(check.status == .updateAvailable && check.commitsBehind == 3 && check.version == "0.9.0+3")
        #expect(check.releaseNotesURL == URL(string: "https://github.com/acme/pal/releases"))
        #expect(check.turnIsRunning && check.hardBlockers.isEmpty && check.canUpdate)
    }

    @Test("check keeps up to date, offline and non-https links apart")
    func checkEdges() async throws {
        let bots = ScriptedBots()
        bots.script("host.update.check", checkReply(status: "up_to_date", behind: 0))
        bots.script("host.update.check", checkReply(status: "unknown", behind: nil, error: "no_network", blockers: ["no_network"]))
        bots.script("host.update.check", checkReply(blockers: ["dirty_install", "from_the_future"], link: "javascript:alert(1)"))
        let upToDate = try await client(bots).check()
        let offline = try await client(bots).check()
        let dirty = try await client(bots).check()
        #expect(upToDate.status == .upToDate && !upToDate.canUpdate)
        #expect(offline.status == .unknown && offline.offline && !offline.canUpdate)
        #expect(dirty.blockers == [.dirtyInstall] && !dirty.canUpdate && dirty.releaseNotesURL == nil)
    }

    @Test("start maps every outcome and sends the confirm flag only when asked")
    func startOutcomes() async {
        let bots = ScriptedBots()
        func apply(_ outcome: String, _ blockers: [String] = []) -> JSONValue {
            .object(["outcome": .string(outcome), "blockers": .array(blockers.map(JSONValue.string)), "update": state("running")])
        }
        bots.script("host.update.apply", apply("refused", ["turn_running"]))
        bots.script("host.update.apply", apply("started"))
        bots.script("host.update.apply", apply("already_running"))
        bots.script("host.update.apply") { _ in throw GatewayTransportError.closed(.normal) }
        #expect(await client(bots).start(confirmTurns: false) == .refused([.turnRunning]))
        #expect(await client(bots).start(confirmTurns: true) == .started)
        #expect(await client(bots).start(confirmTurns: false) == .alreadyRunning)
        #expect(await client(bots).start(confirmTurns: false) == .failed)
        let sent = bots.calls(to: "host.update.apply").map(\.params)
        #expect(sent == [[:], ["confirm_turns": .bool(true)], [:], [:]])
    }

    @Test("a run that stays up walks the phases to the new version")
    func happyPath() async {
        let bots = ScriptedBots()
        bots.script("host.update.status", state("running", phase: "downloading", tail: ["Fetching"]))
        bots.script("host.update.status", state("running", phase: "installing", tail: ["Fetching", "Installing"]))
        bots.script("host.update.status", state("succeeded", phase: "finished", version: "0.9.1"))
        let seen = Mutex<[HostUpdateProgress]>([])
        let final = await client(bots).follow { progress in seen.withLock { $0.append(progress) } }
        #expect(final == .succeeded(version: "0.9.1"))
        #expect(seen.withLock { $0 }.first == .running(phase: .downloading, tail: ["Fetching"]))
    }

    @Test("the gateway going down mid-update shows restarting, then the new version")
    func gatewayDownThenBack() async {
        let bots = ScriptedBots()
        bots.script("host.update.status", state("running", phase: "restarting", tail: ["Restarting"]))
        gatewayDown(bots)
        bots.script("host.update.status", state("succeeded", phase: "finished", version: "0.9.1"))
        let seen = Mutex<[HostUpdateProgress]>([])
        let final = await client(bots).follow { progress in seen.withLock { $0.append(progress) } }
        #expect(final == .succeeded(version: "0.9.1"))
        #expect(seen.withLock { $0 }.contains(.gatewayRestarting(lastPhase: .restarting, tail: ["Restarting"])))
    }

    @Test("a gateway that never returns ends bounded with the last known phase")
    func neverComesBack() async {
        let bots = ScriptedBots()
        bots.script("host.update.status", state("running", phase: "applying"))
        gatewayDown(bots)
        let final = await client(bots, downLimit: 3).follow()
        #expect(final == .didNotComeBack(lastPhase: .applying))
        #expect(bots.calls(to: "host.update.status").count == 4)
    }

    @Test("a gateway that stays up on a run that never ends is bounded too")
    func runIsBounded() async {
        let bots = ScriptedBots()
        bots.script("host.update.status", state("running", phase: "downloading"))
        let final = await client(bots, runLimit: 5).follow()
        #expect(final == .didNotComeBack(lastPhase: .downloading))
        #expect(bots.calls(to: "host.update.status").count == 5)
    }

    @Test("a restarted gateway with no update record is not reported as success")
    func idleAfterOutage() async {
        let bots = ScriptedBots()
        bots.script("host.update.status", state("running", phase: "restarting"))
        gatewayDown(bots)
        bots.script("host.update.status", state("idle"))
        #expect(await client(bots).follow() == .didNotComeBack(lastPhase: .restarting))
    }

    @Test("failures are typed and say whether the old version kept running")
    func failures() async {
        let cases: [(JSONValue, HostUpdateFailure)] = [
            (state("failed", phase: "downloading", failure: "no_network", leftBehind: "nothing"), .noNetwork(lastPhase: .downloading)),
            (state("failed", phase: "applying", failure: "update_failed", leftBehind: "old_version_running"),
             .failed(lastPhase: .applying, oldVersionRunning: true)),
            (state("needs_recovery", phase: "applying", failure: "needs_recovery", leftBehind: "tree_needs_recovery"), .needsRecovery),
            (state("failed", phase: "installing", failure: "interrupted"), .interrupted(lastPhase: .installing)),
            (state("failed", failure: "not_started", leftBehind: "nothing"), .notStarted),
        ]
        for (reply, failure) in cases {
            let bots = ScriptedBots()
            bots.script("host.update.status", reply)
            #expect(await client(bots).follow() == .failed(failure, tail: []))
        }
    }

    @Test("after a reconnect the stored result answers whether the update worked")
    func resultAfterReconnect() async {
        let bots = ScriptedBots()
        bots.script("host.update.status", state("succeeded", phase: "finished", version: "0.9.1"))
        #expect(await client(bots).result() == .succeeded(version: "0.9.1"))
        let offline = ScriptedBots()
        gatewayDown(offline)
        #expect(await client(offline).result() == nil)
    }
}
