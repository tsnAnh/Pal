import Foundation
import PalAuth
import PalLocalEngine
import Synchronization
import Testing

final class ScriptedRunner: EngineProcessRunning {
    typealias Reply = @Sendable (EngineCommand) -> (lines: [String], outcome: EngineProcessOutcome)

    private let calls = Mutex<[EngineCommand]>([])
    private let reply: Reply

    init(_ reply: @escaping Reply) { self.reply = reply }

    var recorded: [EngineCommand] { calls.withLock { $0 } }

    var launcherCalls: [[String]] {
        recorded.filter { $0.executable != "/bin/bash" }.map(\.arguments)
    }

    func run(_ command: EngineCommand, onLine: @escaping @Sendable (EngineOutputLine) -> Void) async -> EngineProcessOutcome {
        calls.withLock { $0.append(command) }
        let answer = reply(command)
        for line in answer.lines { onLine(EngineOutputLine(isError: false, text: line)) }
        return answer.outcome
    }
}

final class FlippingProbe: EngineProbing {
    private let state = Mutex<EngineProbeResult>(.unreachable)
    let seenPorts = Mutex<[Int]>([])

    func set(_ result: EngineProbeResult) { state.withLock { $0 = result } }

    func probe(port: Int, token: LocalToken?) async -> EngineProbeResult {
        seenPorts.withLock { $0.append(port) }
        return state.withLock { $0 }
    }
}

final class EventLog: Sendable {
    private let storage = Mutex<[LocalEngineEvent]>([])
    var events: [LocalEngineEvent] { storage.withLock { $0 } }
    func record(_ event: LocalEngineEvent) { storage.withLock { $0.append(event) } }
}

let engineStageNames = ["prerequisites", "repository", "venv", "python-deps", "config", "products", "setup", "gateway", "complete"]
let manifestLine = "{\"protocol_version\":1,\"stages\":[" + engineStageNames.map { "{\"name\":\"\($0)\"}" }.joined(separator: ",") + "]}"
func frame(_ stage: String, ok: Bool = true, reason: String? = nil) -> String {
    "{\"ok\":\(ok),\"stage\":\"\(stage)\",\"skipped\":false" + (reason.map { ",\"reason\":\"\($0)\"" } ?? "") + "}"
}
func status(installed: Bool, running: Bool, login: Bool = true) -> String {
    "{\"installed\":\(installed),\"loaded\":\(installed),\"running\":\(running),\"pid\":null,"
        + "\"start_on_login\":\(login),\"label\":\"ai.hermes.gateway-0a1b2c3d\"}"
}

final class EngineFixture: @unchecked Sendable {
    let root: URL
    let configuration: LocalEngineConfiguration
    let installer = URL(filePath: "/bundle/install.sh")

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "pal-engine-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        configuration = LocalEngineConfiguration(
            hermesHome: root.appending(path: "home", directoryHint: .isDirectory), userHome: root, preferredPort: 9300
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func installLauncher() throws {
        try FileManager.default.createDirectory(at: configuration.launcher.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: configuration.launcher.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755]
        )
    }

    func writeSessionToken(mode: Int = 0o600) throws {
        let file = configuration.sessionTokenFile.url
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((String(repeating: "t", count: 43) + "\n").utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
    }

    func service(
        runner: ScriptedRunner, probe: FlippingProbe = FlippingProbe(), free: @escaping @Sendable (Int) -> Bool = { _ in true }
    ) -> LocalEngineService {
        LocalEngineService(
            configuration: configuration, installer: installer, runner: runner, probe: probe,
            baseEnvironment: ["PATH": "/usr/bin:/bin", "HERMES_TOKEN": "leak", "SECRET": "leak", "LANG": "en_US.UTF-8"],
            portIsFree: free, makeTrace: { "trace0000001" },
            timing: .init(readyTimeout: .milliseconds(200), readyPollInterval: .milliseconds(20))
        )
    }

    func happyRunner(
        probe: FlippingProbe, failingStage: String? = nil, existing: String? = nil, configuredPort: Int? = nil,
        failing: Set<String> = [], writesToken: Bool = true, installStartsGateway: Bool = true
    ) -> ScriptedRunner {
        let fixture = self
        return ScriptedRunner { command in
            let args = command.arguments
            if args.contains("--manifest") { return ([manifestLine], .exited(code: 0)) }
            if let index = args.firstIndex(of: "--stage") {
                let stage = args[index + 1]
                if stage == failingStage { return ([frame(stage, ok: false, reason: "boom /Users/me/secret")], .exited(code: 1)) }
                return ([frame(stage)], .exited(code: 0))
            }
            let verb = args.prefix(2).joined(separator: " ")
            if failing.contains(verb) { return (["error"], .exited(code: 1)) }
            switch verb {
            case "gateway status": return ([existing ?? status(installed: false, running: false)], .exited(code: 0))
            case "config get": return (configuredPort.map { [String($0)] } ?? ["9120"], .exited(code: 0))
            case "gateway install":
                guard installStartsGateway else { return (["Service already installed"], .exited(code: 0)) }
                if writesToken { try? fixture.writeSessionToken() }
                probe.set(writesToken ? .ready : .running)
                return (["✓ Service installed and loaded!"], .exited(code: 0))
            default: return ([], .exited(code: 0))
            }
        }
    }
}
