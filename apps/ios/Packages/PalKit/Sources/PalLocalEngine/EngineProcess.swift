import Foundation
import PalProcess

public struct EngineCommand: Sendable, Equatable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: String
    public var standardInput: Data?

    public init(
        executable: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String,
        standardInput: Data? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.standardInput = standardInput
    }
}

public struct EngineOutputLine: Sendable, Equatable {
    public let isError: Bool
    public let text: String

    public init(isError: Bool, text: String) {
        self.isError = isError
        self.text = text
    }
}

public enum EngineProcessOutcome: Sendable, Equatable {
    case exited(code: Int)
    case cancelled
    case launchFailed
}

public protocol EngineProcessRunning: Sendable {
    func run(_ command: EngineCommand, onLine: @escaping @Sendable (EngineOutputLine) -> Void) async -> EngineProcessOutcome
}

public protocol EngineLogging: Sendable {
    func write(_ line: String)
}

public enum EngineEnvironment {
    static let passthroughKeys: Set<String> = [
        "USER", "LOGNAME", "SHELL", "LANG", "LC_ALL", "LC_CTYPE", "TMPDIR", "SSL_CERT_FILE", "SSL_CERT_DIR", "SSH_AUTH_SOCK",
        "DEVELOPER_DIR", "http_proxy", "https_proxy", "all_proxy", "no_proxy", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
    ]
    static let systemPath = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
    static let toolPath = ["/opt/homebrew/bin", "/usr/local/bin"]

    public static func make(configuration: LocalEngineConfiguration, base: [String: String]) -> [String: String] {
        var environment = base.filter { passthroughKeys.contains($0.key) }
        let userHome = configuration.userHome.path
        let basePath = base["PATH"].map { $0.split(separator: ":").map(String.init) } ?? []
        var path: [String] = []
        for entry in toolPath + basePath + systemPath + ["\(userHome)/.local/bin"] where !path.contains(entry) { path.append(entry) }
        environment["PATH"] = path.joined(separator: ":")
        environment["HOME"] = userHome
        environment["HERMES_HOME"] = configuration.hermesHome.path
        environment["HERMES_REPO_URL"] = configuration.repositoryURL
        environment["NO_COLOR"] = "1"
        return environment
    }
}

#if os(macOS)
public struct PosixEngineProcessRunner: EngineProcessRunning {
    private let killGrace: TimeInterval

    public init(killGrace: TimeInterval = 5) {
        self.killGrace = killGrace
    }

    public func run(_ command: EngineCommand, onLine: @escaping @Sendable (EngineOutputLine) -> Void) async -> EngineProcessOutcome {
        guard !Task.isCancelled else { return .cancelled }
        let spec = ProcessSpec(
            executable: command.executable,
            arguments: command.arguments,
            environment: command.environment,
            workingDirectory: command.workingDirectory,
            standardInput: command.standardInput
        )
        guard let job = try? ProcessJob.spawn(spec, killGrace: killGrace) else { return .launchFailed }
        let output = LineChannel(isError: false, onLine: onLine)
        let errors = LineChannel(isError: true, onLine: onLine)
        let exit = await withTaskCancellationHandler {
            await job.finish(timeout: nil) { stream, chunk in
                switch stream {
                case .standardOutput: output.feed(chunk)
                case .standardError: errors.feed(chunk)
                }
            }
        } onCancel: {
            job.terminate()
        }
        output.flush()
        errors.flush()
        if exit.terminated || Task.isCancelled { return .cancelled }
        return .exited(code: exit.exitCode ?? -1)
    }
}

private final class LineChannel: @unchecked Sendable {
    private var splitter = OutputLineSplitter()
    private let isError: Bool
    private let onLine: @Sendable (EngineOutputLine) -> Void

    init(isError: Bool, onLine: @escaping @Sendable (EngineOutputLine) -> Void) {
        self.isError = isError
        self.onLine = onLine
    }

    func feed(_ chunk: [UInt8]) {
        for line in splitter.feed(chunk) { onLine(EngineOutputLine(isError: isError, text: line)) }
    }

    func flush() {
        if let line = splitter.finish() { onLine(EngineOutputLine(isError: isError, text: line)) }
    }
}
#endif
