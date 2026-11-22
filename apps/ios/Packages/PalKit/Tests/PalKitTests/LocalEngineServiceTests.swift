import Foundation
import PalAuth
import PalLocalEngine
import Testing

@Suite("Local engine service", .serialized)
struct LocalEngineServiceTests {
    private let fixture: EngineFixture

    init() throws {
        fixture = try EngineFixture()
    }

    private func stages(of runner: ScriptedRunner) -> [String] {
        runner.recorded.compactMap { command in command.arguments.firstIndex(of: "--stage").map { command.arguments[$0 + 1] } }
    }

    @Test func aFreshInstallRunsEveryStageConfiguresTheWebappInstallsTheGatewayAndReturnsASession() async throws {
        let probe = FlippingProbe()
        let runner = fixture.happyRunner(probe: probe)
        let log = EventLog()
        let session = try await fixture.service(runner: runner, probe: probe).install(events: log.record)
        #expect(session == EngineSession(port: 9300, home: fixture.configuration.hermesHome))
        #expect(stages(of: runner) == ["prerequisites", "repository", "venv", "python-deps", "config", "products", "setup", "gateway", "complete"])
        #expect(runner.launcherCalls == [
            ["gateway", "status", "--json"],
            ["config", "set", "webapp.enabled", "true"],
            ["config", "set", "webapp.host", "127.0.0.1"],
            ["config", "set", "webapp.port", "9300"],
            ["gateway", "install"],
        ])
        #expect(log.events.first == .installBegan(step: .download, totalStages: 10))
        #expect(log.events.last == .stageBegan(step: .startPal, completedStages: 9))
        #expect(!FileManager.default.fileExists(atPath: fixture.configuration.incompleteInstallMarker.path))
    }

    @Test func noPublicAddressIsEverConfiguredAndNoCommandCarriesASecret() async throws {
        let probe = FlippingProbe()
        let runner = fixture.happyRunner(probe: probe)
        _ = try await fixture.service(runner: runner, probe: probe).install(events: { _ in })
        let secret = String(repeating: "t", count: 43)
        for command in runner.recorded {
            #expect(!command.arguments.contains { $0.contains("public_url") })
            #expect(!command.arguments.joined(separator: " ").contains(secret))
            #expect(!command.environment.values.contains { $0.contains(secret) })
            #expect(command.standardInput == nil)
            #expect(command.environment["SECRET"] == nil && command.environment["HERMES_TOKEN"] == nil)
            #expect(command.environment["HERMES_HOME"] == fixture.configuration.hermesHome.path)
            #expect(command.environment["HOME"] == fixture.root.path)
            #expect(command.environment["HERMES_REPO_URL"] == LocalEngineConfiguration.repositoryURL)
        }
    }

    @Test func theInstallerRunsUnderBashWithTheUnattendedFlagsAndTheChosenFolders() async throws {
        let probe = FlippingProbe()
        let runner = fixture.happyRunner(probe: probe)
        _ = try await fixture.service(runner: runner, probe: probe).install(events: { _ in })
        let manifest = try #require(runner.recorded.first { $0.arguments.contains("--manifest") })
        #expect(manifest.executable == "/bin/bash")
        #expect(manifest.arguments.contains("--non-interactive") && manifest.arguments.contains("--skip-browser"))
        #expect(manifest.arguments.contains(fixture.configuration.installDirectory.path) && manifest.arguments.contains(fixture.configuration.hermesHome.path))
    }

    @Test func aFailedStageStopsTheRunKeepsTheMarkerAndRetryResumesThere() async throws {
        let probe = FlippingProbe()
        let failing = fixture.service(runner: fixture.happyRunner(probe: probe, failingStage: "venv"), probe: probe)
        do {
            _ = try await failing.install(events: { _ in })
            Issue.record("expected a failure")
        } catch let failure as EngineFailure {
            #expect(failure.code == "install_python_failed" && failure.resumeStage == "venv" && failure.step == .preparePython)
            #expect(!failure.reason.contains("/Users"))
            #expect(failure.trace == "trace0000001")
        }
        #expect(FileManager.default.fileExists(atPath: fixture.configuration.incompleteInstallMarker.path))

        let resumedRunner = fixture.happyRunner(probe: probe)
        let log = EventLog()
        _ = try await fixture.service(runner: resumedRunner, probe: probe).install(resumingFrom: "venv", events: log.record)
        let resumed = stages(of: resumedRunner)
        #expect(resumed.first == "venv" && !resumed.contains("repository"))
        #expect(log.events.first == .installBegan(step: .preparePython, totalStages: 8))
    }

    @Test func aStageThatExitsCleanWithoutAReportIsAFailureNotASuccess() async throws {
        let runner = ScriptedRunner { command in
            command.arguments.contains("--manifest") ? ([manifestLine], .exited(code: 0)) : (["only noise"], .exited(code: 0))
        }
        await #expect(throws: EngineFailure.self) { try await fixture.service(runner: runner).install(events: { _ in }) }
        #expect(runner.launcherCalls.isEmpty)
    }

    @Test func aReportForAnotherStageDoesNotCountAsSuccess() async throws {
        let runner = ScriptedRunner { command in
            command.arguments.contains("--manifest") ? ([manifestLine], .exited(code: 0)) : ([frame("complete")], .exited(code: 0))
        }
        await #expect(throws: EngineFailure.self) { try await fixture.service(runner: runner).install(events: { _ in }) }
    }

    @Test func cancellingTheInstallSurfacesCancellationNotAFailure() async throws {
        let runner = ScriptedRunner { command in
            command.arguments.contains("--manifest") ? ([manifestLine], .exited(code: 0)) : ([], .cancelled)
        }
        await #expect(throws: CancellationError.self) { try await fixture.service(runner: runner).install(events: { _ in }) }
    }

    @Test func anUnreadableManifestIsAnInstallerFailure() async throws {
        let runner = ScriptedRunner { _ in (["garbage"], .exited(code: 0)) }
        do {
            _ = try await fixture.service(runner: runner).install(events: { _ in })
            Issue.record("expected a failure")
        } catch let failure as EngineFailure {
            #expect(failure.code == "install_unavailable")
        }
    }

    @Test func aMissingBundledInstallerCannotStartAnInstall() async throws {
        let runner = ScriptedRunner { _ in ([], .exited(code: 0)) }
        let missing = LocalEngineService(
            configuration: fixture.configuration, installer: nil, runner: runner, probe: FlippingProbe(), makeTrace: { "t" }
        )
        await #expect(throws: EngineFailure.self) { try await missing.install(events: { _ in }) }
        #expect(runner.recorded.isEmpty)
    }

    @Test func anInstalledEngineSkipsEveryInstallerStageAndJustBringsTheGatewayUp() async throws {
        try fixture.installLauncher()
        let probe = FlippingProbe()
        let runner = fixture.happyRunner(probe: probe, existing: status(installed: true, running: false, login: false))
        let log = EventLog()
        let session = try await fixture.service(runner: runner, probe: probe).install(events: log.record)
        #expect(runner.recorded.allSatisfy { $0.executable != "/bin/bash" })
        #expect(log.events == [.installBegan(step: .startPal, totalStages: 1)])
        #expect(session.port == 9300)
        #expect(runner.launcherCalls.contains(["gateway", "install"]) && runner.launcherCalls.contains(["gateway", "start"]))
    }

    @Test func aMarkerFromAnInterruptedInstallMakesTheNextRunInstallAgain() async throws {
        try fixture.installLauncher()
        try FileManager.default.createDirectory(at: fixture.configuration.hermesHome, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: fixture.configuration.incompleteInstallMarker.path, contents: nil)
        let probe = FlippingProbe()
        let runner = fixture.happyRunner(probe: probe)
        _ = try await fixture.service(runner: runner, probe: probe).install(events: { _ in })
        #expect(runner.recorded.contains { $0.arguments.contains("--manifest") })
    }

    @Test func aBusyPreferredPortMovesToTheNextFreeOneAndThatIsWhatTheEngineIsToldToServe() async throws {
        let probe = FlippingProbe()
        let runner = fixture.happyRunner(probe: probe)
        let session = try await fixture.service(runner: runner, probe: probe, free: { $0 >= 9302 }).install(events: { _ in })
        #expect(session.port == 9302)
        #expect(runner.launcherCalls.contains(["config", "set", "webapp.port", "9302"]))
        #expect(probe.seenPorts.withLock { $0.allSatisfy { $0 == 9302 } })
    }

    @Test func aGatewayThatAlreadyRunsKeepsItsOwnPortEvenWhenAnotherIsFree() async throws {
        try fixture.installLauncher()
        let probe = FlippingProbe()
        probe.set(.ready)
        try fixture.writeSessionToken()
        let runner = fixture.happyRunner(
            probe: probe, existing: status(installed: true, running: true), configuredPort: 9305
        )
        let session = try await fixture.service(runner: runner, probe: probe, free: { $0 != 9305 }).install(events: { _ in })
        #expect(session.port == 9305)
        #expect(runner.launcherCalls.contains(["config", "set", "webapp.port", "9305"]))
        #expect(!runner.launcherCalls.contains(["gateway", "restart"]) && !runner.launcherCalls.contains(["gateway", "start"]))
    }

    @Test func aRunningGatewayThatDoesNotServeTheWebappYetIsRestartedNotLeftAlone() async throws {
        try fixture.installLauncher()
        let probe = FlippingProbe()
        let runner = fixture.happyRunner(probe: probe, existing: status(installed: true, running: true), installStartsGateway: false)
        _ = try? await fixture.service(runner: runner, probe: probe).install(events: { _ in })
        #expect(runner.launcherCalls.contains(["gateway", "restart"]))
    }

    @Test func noFreePortInTheSearchWindowIsAPortFailureBeforeAnythingIsConfigured() async throws {
        try fixture.installLauncher()
        let runner = fixture.happyRunner(probe: FlippingProbe())
        do {
            _ = try await fixture.service(runner: runner, free: { _ in false }).install(events: { _ in })
            Issue.record("expected a failure")
        } catch let failure as EngineFailure {
            #expect(failure.code == "port_in_use" && failure.step == .startPal)
        }
        #expect(!runner.launcherCalls.contains { $0.first == "config" })
    }

    @Test func aConfigurationFailureStopsBeforeTheGatewayIsInstalled() async throws {
        try fixture.installLauncher()
        let runner = fixture.happyRunner(probe: FlippingProbe(), failing: ["config set"])
        do {
            _ = try await fixture.service(runner: runner).install(events: { _ in })
            Issue.record("expected a failure")
        } catch let failure as EngineFailure {
            #expect(failure.code == "config_failed" && failure.resumeStage == nil)
            #expect(!failure.reason.contains("/Users"))
        }
        #expect(!runner.launcherCalls.contains(["gateway", "install"]))
    }

    @Test func aGatewayInstallFailureIsReportedWithItsOwnCode() async throws {
        try fixture.installLauncher()
        let runner = fixture.happyRunner(probe: FlippingProbe(), failing: ["gateway install"])
        do {
            _ = try await fixture.service(runner: runner).install(events: { _ in })
            Issue.record("expected a failure")
        } catch let failure as EngineFailure {
            #expect(failure.code == "gateway_install_failed" && failure.step == .startPal)
        }
    }

    @Test func aGatewayThatNeverAnswersIsReportedAfterTheWait() async throws {
        try fixture.installLauncher()
        let probe = FlippingProbe()
        let runner = ScriptedRunner { _ in ([status(installed: false, running: false)], .exited(code: 0)) }
        do {
            _ = try await fixture.service(runner: runner, probe: probe).install(events: { _ in })
            Issue.record("expected a failure")
        } catch let failure as EngineFailure {
            #expect(failure.code == "service_not_responding")
        }
    }

    @Test func anEngineThatAnswersButLeavesNoReadableTokenIsATokenFailure() async throws {
        try fixture.installLauncher()
        let probe = FlippingProbe()
        probe.set(.running)
        let runner = fixture.happyRunner(probe: probe, writesToken: false)
        do {
            _ = try await fixture.service(runner: runner, probe: probe).install(events: { _ in })
            Issue.record("expected a failure")
        } catch let failure as EngineFailure {
            #expect(failure.code == "token_unavailable")
        }
    }
}
