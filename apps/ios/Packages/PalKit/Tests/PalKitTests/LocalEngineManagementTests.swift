import Foundation
import PalAuth
import PalLocalEngine
import Testing

@Suite("Local engine management", .serialized)
struct LocalEngineManagementTests {
    private let fixture: EngineFixture

    init() throws {
        fixture = try EngineFixture()
    }

    @Test func detectionReadsReadyStoppedRunningAndNotInstalled() async throws {
        let probe = FlippingProbe()
        let runner = ScriptedRunner { command in
            command.arguments.first == "config" ? (["9300"], .exited(code: 0)) : ([status(installed: true, running: false)], .exited(code: 0))
        }
        let engine = fixture.service(runner: runner, probe: probe)
        #expect(await engine.detect().detection == .notInstalled)
        try fixture.installLauncher()
        #expect(await engine.detect().detection == .stopped)
        probe.set(.running)
        #expect(await engine.detect().detection == .stopped)
        try fixture.writeSessionToken()
        probe.set(.ready)
        let ready = await engine.detect()
        #expect(ready.detection == .ready && ready.session == EngineSession(port: 9300, home: fixture.configuration.hermesHome))
    }

    @Test func aRunningGatewayWithoutAReadableTokenIsRunningButNeverReady() async throws {
        try fixture.installLauncher()
        let probe = FlippingProbe()
        probe.set(.ready)
        let runner = ScriptedRunner { command in
            command.arguments.first == "config" ? (["9300"], .exited(code: 0)) : ([status(installed: true, running: true)], .exited(code: 0))
        }
        let result = await fixture.service(runner: runner, probe: probe).detect()
        #expect(result.detection == .running && result.session == nil)
    }

    @Test func aGatewayServingAnotherPortThanThePreferredOneIsFoundThroughItsConfiguration() async throws {
        try fixture.installLauncher()
        try fixture.writeSessionToken()
        let runner = ScriptedRunner { command in
            command.arguments.first == "config" ? (["9311"], .exited(code: 0)) : ([status(installed: true, running: true)], .exited(code: 0))
        }
        let engine = LocalEngineService(
            configuration: fixture.configuration, installer: nil, runner: runner, probe: ReadyOnlyOn9311(), makeTrace: { "t" }
        )
        let result = await engine.detect()
        #expect(result.detection == .ready && result.session?.port == 9311)
    }

    @Test func startAtLoginReinstallsWithTheFlagAndAnswersTheNewState() async throws {
        let runner = ScriptedRunner { command in
            command.arguments.first == "gateway" && command.arguments[1] == "install"
                ? ([], .exited(code: 0)) : ([status(installed: true, running: true, login: false)], .exited(code: 0))
        }
        let result = try await fixture.service(runner: runner).setStartAtLogin(false)
        #expect(!result.startOnLogin)
        #expect(runner.launcherCalls.first == ["gateway", "install", "--no-start-on-login"])
        _ = try await fixture.service(runner: runner).setStartAtLogin(true)
        #expect(runner.launcherCalls.contains(["gateway", "install", "--start-on-login"]))
    }

    @Test func aFailedStartAtLoginChangeIsReportedInPlainWordsWithItsCode() async throws {
        let runner = fixture.happyRunner(probe: FlippingProbe(), failing: ["gateway install"])
        do {
            _ = try await fixture.service(runner: runner).setStartAtLogin(false)
            Issue.record("expected a failure")
        } catch let failure as EngineFailure {
            #expect(failure.code == "login_setting_failed" && failure.trace == "trace0000001")
        }
    }

    @Test func startingAnAlreadyReadyEngineTouchesNothing() async throws {
        try fixture.installLauncher()
        try fixture.writeSessionToken()
        let probe = FlippingProbe()
        probe.set(.ready)
        let runner = fixture.happyRunner(probe: probe, existing: status(installed: true, running: true), configuredPort: 9300)
        let session = try await fixture.service(runner: runner, probe: probe).startIfStopped()
        #expect(session?.port == 9300)
        #expect(runner.launcherCalls == [["config", "get", "webapp.port"]])
    }

    @Test func startingAStoppedInstalledEngineStartsTheGatewayAndWaitsUntilItAnswers() async throws {
        try fixture.installLauncher()
        let probe = FlippingProbe()
        let runner = ScriptedRunner { command in
            if command.arguments.prefix(2) == ["gateway", "start"] {
                try? fixture.writeSessionToken()
                probe.set(.ready)
                return ([], .exited(code: 0))
            }
            if command.arguments.first == "config" { return (["9300"], .exited(code: 0)) }
            return ([status(installed: true, running: false)], .exited(code: 0))
        }
        let session = try await fixture.service(runner: runner, probe: probe).startIfStopped()
        #expect(session?.port == 9300)
        #expect(runner.launcherCalls.contains(["gateway", "start"]))
    }

    @Test func startingWhenNothingIsInstalledDoesNothing() async throws {
        let runner = ScriptedRunner { _ in ([], .exited(code: 0)) }
        #expect(try await fixture.service(runner: runner).startIfStopped() == nil)
        #expect(!runner.launcherCalls.contains { $0.first == "gateway" })
    }

    @Test func aGatewayThatWillNotStartIsAFailureNotASilentNil() async throws {
        try fixture.installLauncher()
        let runner = ScriptedRunner { command in
            command.arguments.prefix(2) == ["gateway", "start"]
                ? (["error"], .exited(code: 1)) : (command.arguments.first == "config" ? (["9300"], .exited(code: 0))
                    : ([status(installed: true, running: false)], .exited(code: 0)))
        }
        do {
            _ = try await fixture.service(runner: runner).startIfStopped()
            Issue.record("expected a failure")
        } catch let failure as EngineFailure {
            #expect(failure.code == "gateway_install_failed")
        }
    }

    @Test func removeUninstallsTheGatewayThenTheProgramKeepingDataByDefault() async throws {
        try fixture.installLauncher()
        let runner = ScriptedRunner { _ in ([], .exited(code: 0)) }
        try await fixture.service(runner: runner).remove(deleteData: false)
        #expect(runner.launcherCalls == [["gateway", "uninstall"], ["uninstall", "--yes"]])
    }

    @Test func removeWithDeleteDataAddsTheFullFlag() async throws {
        try fixture.installLauncher()
        let runner = ScriptedRunner { _ in ([], .exited(code: 0)) }
        try await fixture.service(runner: runner).remove(deleteData: true)
        #expect(runner.launcherCalls.last == ["uninstall", "--yes", "--full"])
    }

    @Test func aFailedUninstallIsARemoveFailureAndRemovalCanBeRetried() async throws {
        try fixture.installLauncher()
        let runner = ScriptedRunner { command in
            command.arguments.first == "uninstall" ? (["error"], .exited(code: 1)) : ([], .exited(code: 0))
        }
        do {
            try await fixture.service(runner: runner).remove(deleteData: false)
            Issue.record("expected a failure")
        } catch let failure as EngineFailure {
            #expect(failure.code == "remove_failed" && failure.operation == .remove)
        }
    }

    @Test func aGatewayUninstallRefusalStopsBeforeTheProgramIsRemoved() async throws {
        try fixture.installLauncher()
        let runner = ScriptedRunner { _ in (["✗ Refusing to uninstall"], .exited(code: 1)) }
        do {
            try await fixture.service(runner: runner).remove(deleteData: true)
            Issue.record("expected a failure")
        } catch let failure as EngineFailure {
            #expect(failure.code == "remove_failed")
        }
        #expect(runner.launcherCalls == [["gateway", "uninstall"]])
    }

    @Test func removingWhenNothingIsInstalledRunsNothing() async throws {
        let runner = ScriptedRunner { _ in ([], .exited(code: 0)) }
        try await fixture.service(runner: runner).remove(deleteData: true)
        #expect(runner.recorded.isEmpty)
    }

    @Test func theTestOverridesChangeOnlyWhatTheyNameAndRejectBadPorts() {
        let base = LocalEngineConfiguration.standard(userHome: URL(filePath: "/Users/real"))
        let changed = LocalEngineOverrides.configuration(
            arguments: ["-hermes-test-engine-home", "/scratch/home", "-hermes-test-engine-port", "9411", "-hermes-test-engine-user-home", "/scratch/user",
                        "-hermes-test-engine-repo", "file:///repo", "-hermes-test-engine-branch", "work"],
            base: base
        )
        #expect(changed.hermesHome.path == "/scratch/home" && changed.installDirectory.path == "/scratch/home/hermes-agent")
        #expect(changed.preferredPort == 9411 && changed.userHome.path == "/scratch/user")
        #expect(changed.repositoryURL == "file:///repo" && changed.branch == "work")
        #expect(LocalEngineOverrides.configuration(arguments: [], base: base) == base)
        #expect(LocalEngineOverrides.configuration(arguments: ["-hermes-test-engine-port", "99999"], base: base) == base)
        #expect(LocalEngineOverrides.configuration(arguments: ["-hermes-test-engine-port"], base: base) == base)
        #expect(base.hermesHome.path == "/Users/real/.hermes" && base.launcher.path == "/Users/real/.hermes/hermes-agent/.hermes/bin/hermes")
        #expect(base.preferredPort == 9120 && base.sessionTokenFile.url.path == "/Users/real/.hermes/webapp/session-token")
    }
}

private final class ReadyOnlyOn9311: EngineProbing {
    func probe(port: Int, token: LocalToken?) async -> EngineProbeResult {
        port == 9311 && token != nil ? .ready : .unreachable
    }
}
