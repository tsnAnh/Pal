import Foundation
import PalAuth
import Synchronization

public struct EngineSession: Sendable, Equatable {
    public let port: Int
    public let home: URL

    public init(port: Int, home: URL) {
        self.port = port
        self.home = home
    }
}

public struct EngineDetectionResult: Sendable, Equatable {
    public let detection: EngineDetection
    public let session: EngineSession?
}

public actor LocalEngineService {
    public struct Timing: Sendable {
        public var readyTimeout: Duration
        public var readyPollInterval: Duration

        public init(readyTimeout: Duration = .seconds(120), readyPollInterval: Duration = .seconds(1)) {
            self.readyTimeout = readyTimeout
            self.readyPollInterval = readyPollInterval
        }
    }

    public typealias Events = @Sendable (LocalEngineEvent) -> Void

    private let configuration: LocalEngineConfiguration
    private let installer: URL?
    private let runner: any EngineProcessRunning
    private let probe: any EngineProbing
    private let log: (any EngineLogging)?
    private let baseEnvironment: [String: String]
    private let portIsFree: @Sendable (Int) -> Bool
    private let makeTrace: @Sendable () -> String
    private let timing: Timing

    public init(
        configuration: LocalEngineConfiguration,
        installer: URL?,
        runner: any EngineProcessRunning,
        probe: any EngineProbing,
        log: (any EngineLogging)? = nil,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        portIsFree: @escaping @Sendable (Int) -> Bool = PortAvailability.isFree,
        makeTrace: @escaping @Sendable () -> String = EngineFailure.makeTrace,
        timing: Timing = Timing()
    ) {
        self.configuration = configuration
        self.installer = installer
        self.runner = runner
        self.probe = probe
        self.log = log
        self.baseEnvironment = baseEnvironment
        self.portIsFree = portIsFree
        self.makeTrace = makeTrace
        self.timing = timing
    }

    public func detect() async -> EngineDetectionResult {
        if let session = await readySession(port: configuration.preferredPort) {
            return EngineDetectionResult(detection: .ready, session: session)
        }
        guard configuration.isInstalled else { return EngineDetectionResult(detection: .notInstalled, session: nil) }
        let status = try? await gatewayStatus()
        if let port = await configuredPort(), port != configuration.preferredPort, let session = await readySession(port: port) {
            return EngineDetectionResult(detection: .ready, session: session)
        }
        return EngineDetectionResult(detection: status?.running == true ? .running : .stopped, session: nil)
    }

    public func serviceStatus() async throws -> GatewayServiceStatus {
        let trace = makeTrace()
        guard let status = try await gatewayStatus() else {
            log?.write("trace \(trace) gateway status unreadable")
            throw EngineFailure.gatewayInstall(trace: trace)
        }
        return status
    }

    public func install(resumingFrom resumeStage: String? = nil, events: @escaping Events) async throws -> EngineSession {
        if configuration.isInstalled && resumeStage == nil {
            events(.installBegan(step: .startPal, totalStages: 1))
        } else {
            try await runInstaller(resumingFrom: resumeStage, events: events)
        }
        return try await startGateway()
    }

    public func startIfStopped() async throws -> EngineSession? {
        let port = await configuredPort() ?? configuration.preferredPort
        if let session = await readySession(port: port) { return session }
        guard configuration.isInstalled, let status = try await gatewayStatus(), status.installed else { return nil }
        let trace = makeTrace()
        if !status.running {
            let outcome = try await launcher(["gateway", "start"], label: "gateway start")
            guard outcome.code == 0 else {
                log?.write("trace \(trace) gateway start failed exit=\(outcome.code)")
                throw EngineFailure.gatewayInstall(trace: trace)
            }
        }
        try await waitUntilReady(port: port, trace: trace)
        return EngineSession(port: port, home: configuration.hermesHome)
    }

    public func setStartAtLogin(_ enabled: Bool) async throws -> GatewayServiceStatus {
        let trace = makeTrace()
        let flag = enabled ? "--start-on-login" : "--no-start-on-login"
        let outcome = try await launcher(["gateway", "install", flag], label: "gateway install")
        guard outcome.code == 0, let status = try await gatewayStatus() else {
            log?.write("trace \(trace) start at login change failed exit=\(outcome.code)")
            throw EngineFailure.loginSetting(trace: trace)
        }
        return status
    }

    public func remove(deleteData: Bool) async throws {
        let trace = makeTrace()
        guard configuration.launcherExists else { return }
        for arguments in [["gateway", "uninstall"], ["uninstall", "--yes"] + (deleteData ? ["--full"] : [])] {
            let outcome = try await launcher(arguments, label: arguments.joined(separator: " "))
            guard outcome.code == 0 else {
                log?.write("trace \(trace) \(arguments.joined(separator: " ")) failed exit=\(outcome.code)")
                throw EngineFailure.removalFailed(trace: trace)
            }
        }
    }
}

extension LocalEngineService {
    private func startGateway() async throws -> EngineSession {
        let trace = makeTrace()
        let before = try await gatewayStatus()
        let reusable = before?.running == true ? await configuredPort() : nil
        guard let port = reusable ?? PortAvailability.firstFree(
            from: configuration.preferredPort, limit: LocalEngineConfiguration.portSearchLimit, isFree: portIsFree
        ) else {
            throw EngineFailure.portInUse(trace: trace)
        }
        try await configure(port: port, trace: trace)
        let installed = try await launcher(["gateway", "install"], label: "gateway install")
        guard installed.code == 0 else {
            log?.write("trace \(trace) gateway install failed exit=\(installed.code)")
            throw EngineFailure.gatewayInstall(trace: trace)
        }
        try await bringUp(previous: before, port: port, trace: trace)
        try await waitUntilReady(port: port, trace: trace)
        markInstallComplete()
        return EngineSession(port: port, home: configuration.hermesHome)
    }

    private func configure(port: Int, trace: String) async throws {
        let settings = [("webapp.enabled", "true"), ("webapp.host", LocalEngineCredential.host), ("webapp.port", String(port))]
        for (key, value) in settings {
            let outcome = try await launcher(["config", "set", key, value], label: "config set \(key)")
            guard outcome.code == 0 else {
                log?.write("trace \(trace) config set \(key) failed exit=\(outcome.code)")
                throw EngineFailure.configuration(trace: trace)
            }
        }
    }

    private func bringUp(previous: GatewayServiceStatus?, port: Int, trace: String) async throws {
        guard let previous, previous.installed else { return }
        if previous.running, await readySession(port: port) != nil { return }
        let verb = previous.running ? "restart" : "start"
        let outcome = try await launcher(["gateway", verb], label: "gateway \(verb)")
        guard outcome.code == 0 else {
            log?.write("trace \(trace) gateway \(verb) failed exit=\(outcome.code)")
            throw EngineFailure.gatewayInstall(trace: trace)
        }
    }

    private func waitUntilReady(port: Int, trace: String) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timing.readyTimeout
        var last = EngineProbeResult.unreachable
        var tokenReadable = false
        while true {
            try Task.checkCancellation()
            let token = try? configuration.sessionTokenFile.read()
            tokenReadable = token != nil
            last = await probe.probe(port: port, token: token)
            if last == .ready { return }
            guard clock.now < deadline else { break }
            try await Task.sleep(for: timing.readyPollInterval)
        }
        log?.write("trace \(trace) engine not ready: \(last) tokenReadable=\(tokenReadable)")
        throw last == .running ? EngineFailure.tokenUnavailable(trace: trace) : EngineFailure.engineNotResponding(trace: trace)
    }

    private func readySession(port: Int) async -> EngineSession? {
        let token = try? configuration.sessionTokenFile.read()
        guard let token, await probe.probe(port: port, token: token) == .ready else { return nil }
        return EngineSession(port: port, home: configuration.hermesHome)
    }

    private func markInstallComplete() {
        try? FileManager.default.removeItem(at: configuration.incompleteInstallMarker)
    }

    private func markInstallIncomplete() {
        let manager = FileManager.default
        try? manager.createDirectory(at: configuration.hermesHome, withIntermediateDirectories: true)
        manager.createFile(atPath: configuration.incompleteInstallMarker.path, contents: nil)
    }
}

extension LocalEngineService {
    private func runInstaller(resumingFrom resumeStage: String?, events: @escaping Events) async throws {
        let trace = makeTrace()
        markInstallIncomplete()
        let manifest = try await fetchManifest(trace: trace)
        let stages = manifest.stages(from: resumeStage)
        guard let first = stages.first else { throw EngineFailure.installerUnavailable(trace: trace) }
        events(.installBegan(step: first.step, totalStages: stages.count + 1))
        for (index, stage) in stages.enumerated() {
            try Task.checkCancellation()
            events(.stageBegan(step: stage.step, completedStages: index))
            try await run(stage: stage, trace: trace)
        }
        events(.stageBegan(step: .startPal, completedStages: stages.count))
    }

    private func fetchManifest(trace: String) async throws -> InstallManifest {
        let lines = LineCollector()
        let outcome = await execute(installerCommand(["--manifest"]), label: "manifest") { line in
            if !line.isError { lines.append(line.text) }
        }
        switch outcome {
        case .cancelled: throw CancellationError()
        case .launchFailed, .exited(code: 1...):
            log?.write("trace \(trace) manifest unavailable: \(outcome)")
            throw EngineFailure.installerUnavailable(trace: trace)
        case .exited:
            guard let line = lines.values.last(where: { $0.hasPrefix("{") }), let manifest = try? InstallManifest.parse(Data(line.utf8)) else {
                log?.write("trace \(trace) manifest unreadable")
                throw EngineFailure.installerUnavailable(trace: trace)
            }
            return manifest
        }
    }

    private func run(stage: InstallStage, trace: String) async throws {
        let reports = ReportBox()
        let outcome = await execute(installerCommand(["--stage", stage.name, "--json"]), label: stage.name) { line in
            if !line.isError, let report = StageReport.parse(line: line.text) { reports.set(report) }
        }
        switch outcome {
        case .cancelled:
            throw CancellationError()
        case .launchFailed:
            log?.write("trace \(trace) stage \(stage.name) could not start")
            throw EngineFailure.installerUnavailable(trace: trace)
        case .exited(let code):
            let report = reports.value.flatMap { $0.stage == stage.name ? $0 : nil }
            if code == 0, report?.ok == true { return }
            log?.write("trace \(trace) stage \(stage.name) failed exit=\(code) reason=\(report?.reason ?? "none")")
            throw EngineFailure.install(stage: stage, report: report, trace: trace)
        }
    }
}

extension LocalEngineService {
    private struct LauncherOutcome {
        let code: Int
        let lines: [String]
    }

    private func installerCommand(_ extra: [String]) -> EngineCommand? {
        guard let installer else { return nil }
        return EngineCommand(
            executable: "/bin/bash",
            arguments: [
                installer.path, "--non-interactive", "--skip-browser", "--branch", configuration.branch,
                "--dir", configuration.installDirectory.path,
                "--hermes-home", configuration.hermesHome.path,
            ] + extra,
            environment: EngineEnvironment.make(configuration: configuration, base: baseEnvironment),
            workingDirectory: configuration.userHome.path
        )
    }

    private func launcherCommand(_ arguments: [String]) -> EngineCommand {
        EngineCommand(
            executable: configuration.launcher.path,
            arguments: arguments,
            environment: EngineEnvironment.make(configuration: configuration, base: baseEnvironment),
            workingDirectory: configuration.userHome.path
        )
    }

    private func execute(
        _ command: EngineCommand?, label: String, onLine: @escaping @Sendable (EngineOutputLine) -> Void = { _ in }
    ) async -> EngineProcessOutcome {
        guard let command else { return .launchFailed }
        let log = log
        return await runner.run(command) { line in
            log?.write("[\(label)] \(line.text)")
            onLine(line)
        }
    }

    private func launcher(_ arguments: [String], label: String) async throws -> LauncherOutcome {
        let lines = LineCollector()
        let outcome = await execute(launcherCommand(arguments), label: label) { line in
            if !line.isError { lines.append(line.text) }
        }
        switch outcome {
        case .cancelled: throw CancellationError()
        case .launchFailed: return LauncherOutcome(code: -1, lines: [])
        case .exited(let code): return LauncherOutcome(code: code, lines: lines.values)
        }
    }

    private func gatewayStatus() async throws -> GatewayServiceStatus? {
        let outcome = try await launcher(["gateway", "status", "--json"], label: "gateway status")
        return outcome.code == 0 ? GatewayServiceStatus.parse(lines: outcome.lines) : nil
    }

    private func configuredPort() async -> Int? {
        guard let outcome = try? await launcher(["config", "get", "webapp.port"], label: "config get webapp.port"), outcome.code == 0 else {
            return nil
        }
        return outcome.lines.reversed().lazy.compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }.first { (1...65_535).contains($0) }
    }
}

private final class LineCollector: Sendable {
    private let storage = Mutex<[String]>([])

    var values: [String] { storage.withLock { $0 } }

    func append(_ line: String) {
        storage.withLock { $0.append(line) }
    }
}

private final class ReportBox: Sendable {
    private let storage = Mutex<StageReport?>(nil)

    var value: StageReport? { storage.withLock { $0 } }

    func set(_ report: StageReport) {
        storage.withLock { $0 = report }
    }
}
