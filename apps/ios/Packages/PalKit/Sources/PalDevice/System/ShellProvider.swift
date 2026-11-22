#if os(macOS)
import Foundation
import PalProcess

public struct SystemShell: ShellProviding {
    private static let killGrace: TimeInterval = 2

    public init() {}

    public func run(command: String, workingDirectory: String?, timeout: Duration, captureLimit: Int) async throws -> ShellRunRecord {
        try Task.checkCancellation()
        let directory = try Self.resolveDirectory(workingDirectory)
        let spec = ProcessSpec(
            executable: Self.loginShell(),
            arguments: ["-l", "-c", command],
            environment: ProcessInfo.processInfo.environment,
            workingDirectory: directory
        )
        let job: ProcessJob
        do {
            job = try ProcessJob.spawn(spec, killGrace: Self.killGrace)
        } catch ProcessLaunchError.spawn(let code) {
            throw DeviceProviderError.failed("The command could not be started: \(String(cString: strerror(code))).")
        } catch {
            throw DeviceProviderError.failed("The command could not be started.")
        }
        let keep = captureLimit + DeviceTextLimit.slack
        let out = OutputCollector(keep: keep)
        let err = OutputCollector(keep: keep)
        let exit = await withTaskCancellationHandler {
            await job.finish(timeout: timeout) { stream, chunk in
                switch stream {
                case .standardOutput: out.append(chunk)
                case .standardError: err.append(chunk)
                }
            }
        } onCancel: {
            job.terminate()
        }
        return ShellRunRecord(
            exitCode: exit.exitCode,
            stdout: TextCap.capture(out.bytes, totalBytes: out.total, limit: captureLimit),
            stderr: TextCap.capture(err.bytes, totalBytes: err.total, limit: captureLimit),
            timedOut: exit.terminated
        )
    }

    static func loginShell() -> String {
        if let configured = ProcessInfo.processInfo.environment["SHELL"], configured.hasPrefix("/"), access(configured, X_OK) == 0 {
            return configured
        }
        return "/bin/zsh"
    }

    static func resolveDirectory(_ raw: String?) throws -> String {
        let path = try raw.map { try DevicePath.resolve($0) } ?? NSHomeDirectory()
        var info = stat()
        guard stat(path, &info) == 0 else { throw PosixError.map(errno, path: path, action: "open") }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw DeviceProviderError.invalidArgs("cwd \(path) is not a folder.") }
        guard access(path, X_OK) == 0 else { throw PosixError.map(errno, path: path, action: "open") }
        return path
    }
}

private final class OutputCollector: @unchecked Sendable {
    private let keep: Int
    private(set) var bytes: [UInt8] = []
    private(set) var total = 0

    init(keep: Int) { self.keep = keep }

    func append(_ chunk: [UInt8]) {
        total += chunk.count
        let room = keep - bytes.count
        if room > 0 { bytes.append(contentsOf: chunk[0..<min(chunk.count, room)]) }
    }
}
#endif
