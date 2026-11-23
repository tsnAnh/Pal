import Foundation
import PalLocalEngine
import Synchronization
import Testing

final class CapturingLog: EngineLogging {
    private let storage = Mutex<[String]>([])
    var lines: [String] { storage.withLock { $0 } }
    func write(_ line: String) { storage.withLock { $0.append(line) } }
}

private let secret = "fixture-password-marker"
private let onJSON = "{\"enabled\":true,\"url\":\"http://100.64.0.7:9120\",\"username\":\"pal\",\"password\":\"\(secret)\",\"reachable\":true}"
private let statusOnJSON = "{\"enabled\":true,\"url\":\"http://100.64.0.7:9120\",\"username\":\"pal\",\"reachable\":false}"
private let offJSON = "{\"enabled\":false,\"url\":null,\"username\":null,\"reachable\":null}"

@Suite("Local engine tailnet", .serialized)
struct LocalEngineTailnetTests {
    private let fixture: EngineFixture
    private let log = CapturingLog()

    init() throws {
        fixture = try EngineFixture()
        try fixture.installLauncher()
    }

    private func service(_ reply: @escaping ScriptedRunner.Reply) -> (LocalEngineService, ScriptedRunner) {
        let runner = ScriptedRunner(reply)
        let service = LocalEngineService(
            configuration: fixture.configuration, installer: nil, runner: runner, probe: FlippingProbe(), log: log,
            makeTrace: { "trace0000001" }
        )
        return (service, runner)
    }

    @Test func statusDecodesOffAndOn() async throws {
        let (off, offRunner) = service { _ in ([offJSON], .exited(code: 0)) }
        #expect(try await off.tailnetStatus() == TailnetStatus(enabled: false, url: nil, username: nil, reachable: nil))
        #expect(offRunner.launcherCalls == [["tailnet", "status", "--json"]])
        let (on, _) = service { _ in ([statusOnJSON], .exited(code: 0)) }
        #expect(
            try await on.tailnetStatus()
                == TailnetStatus(enabled: true, url: "http://100.64.0.7:9120", username: "pal", reachable: false)
        )
    }

    @Test func enableDecodesCredentials() async throws {
        let (engine, runner) = service { _ in ([onJSON], .exited(code: 0)) }
        let credentials = try await engine.enableTailnet()
        #expect(credentials.url == "http://100.64.0.7:9120")
        #expect(credentials.username == "pal")
        #expect(credentials.password == secret)
        #expect(credentials.reachable)
        #expect(runner.launcherCalls == [["tailnet", "on", "--json"]])
    }

    @Test func disableDecodesStatusAndRunsOff() async throws {
        let (engine, runner) = service { _ in ([offJSON], .exited(code: 0)) }
        #expect(try await engine.disableTailnet().enabled == false)
        #expect(runner.launcherCalls == [["tailnet", "off", "--json"]])
    }

    @Test func multilineJSONDecodes() async throws {
        let (engine, _) = service { _ in (["{", "\"enabled\": false,", "\"url\": null, \"username\": null, \"reachable\": null", "}"], .exited(code: 0)) }
        #expect(try await engine.tailnetStatus().enabled == false)
    }

    @Test func errorJSONWithExitOneBecomesTailnetErrorWithThatMessage() async throws {
        let message = "Tailscale isn't running on this Mac."
        let (engine, _) = service { _ in (["{\"error\": \"\(message)\"}"], .exited(code: 1)) }
        for call in [{ try await engine.tailnetStatus() as Any }, { try await engine.enableTailnet() as Any }, { try await engine.disableTailnet() as Any }] {
            do {
                _ = try await call()
                Issue.record("expected a throw")
            } catch let error as TailnetError {
                #expect(error.message == message)
            }
        }
    }

    @Test func undecodableOutputWithExitZeroIsTheGenericFailure() async throws {
        let (engine, _) = service { _ in (["not json at all"], .exited(code: 0)) }
        await #expect(throws: EngineFailure.tailnet(trace: "trace0000001")) { try await engine.tailnetStatus() }
        await #expect(throws: EngineFailure.tailnet(trace: "trace0000001")) { try await engine.enableTailnet() }
    }

    @Test func nonZeroExitWithoutJSONIsTheGenericFailure() async throws {
        let (engine, _) = service { _ in (["Traceback (most recent call last):"], .exited(code: 1)) }
        await #expect(throws: EngineFailure.tailnet(trace: "trace0000001")) { try await engine.disableTailnet() }
    }

    @Test func aLauncherThatCannotStartIsTheGenericFailure() async throws {
        let (engine, _) = service { _ in ([], .launchFailed) }
        await #expect(throws: EngineFailure.tailnet(trace: "trace0000001")) { try await engine.tailnetStatus() }
    }

    @Test func theGenericFailureReadsInProductLanguage() {
        let failure = EngineFailure.tailnet(trace: "t")
        #expect(!failure.reason.isEmpty)
        #expect(!failure.reason.lowercased().contains("json"))
    }

    @Test func thePasswordReachesNoLogLineNoErrorAndNoTextForm() async throws {
        let (engine, _) = service { _ in ([onJSON], .exited(code: 0)) }
        let credentials = try await engine.enableTailnet()
        var dumped = ""
        dump(credentials, to: &dumped)
        for text in ["\(credentials)", String(reflecting: credentials), dumped] { #expect(!text.contains(secret)) }
        #expect(!log.lines.isEmpty)
        for line in log.lines { #expect(!line.contains(secret)) }
        #expect(log.lines.contains { $0.contains("trace0000001") && $0.contains("exit=0") })

        let (broken, _) = service { _ in ([onJSON + " trailing"], .exited(code: 0)) }
        do {
            _ = try await broken.enableTailnet()
            Issue.record("expected a throw")
        } catch {
            #expect(!"\(error)".contains(secret))
            #expect(!String(reflecting: error).contains(secret))
        }
        for line in log.lines { #expect(!line.contains(secret)) }
    }

    @Test func aFailingEnableLogsOnlyTraceAndExitCode() async throws {
        let (engine, _) = service { _ in ([onJSON, "{\"error\": \"x\"}"], .exited(code: 1)) }
        _ = try? await engine.enableTailnet()
        for line in log.lines { #expect(!line.contains(secret) && !line.contains("password")) }
        #expect(log.lines.contains { $0.contains("exit=1") })
    }
}
