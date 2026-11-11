#if os(macOS)
import Foundation
import Synchronization

public struct SystemShell: ShellProviding {
    private static let killGrace: TimeInterval = 2

    public init() {}

    public func run(command: String, workingDirectory: String?, timeout: Duration, captureLimit: Int) async throws -> ShellRunRecord {
        try Task.checkCancellation()
        let directory = try Self.resolveDirectory(workingDirectory)
        let job = try ShellJob.spawn(command: command, directory: directory, shell: Self.loginShell(), killGrace: Self.killGrace)
        return await withTaskCancellationHandler {
            await job.finish(timeout: timeout, captureLimit: captureLimit)
        } onCancel: {
            job.terminate()
        }
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

    func append(_ buffer: [UInt8], count: Int) {
        total += count
        let room = keep - bytes.count
        if room > 0 { bytes.append(contentsOf: buffer[0..<min(count, room)]) }
    }
}

private struct ShellExit: Sendable {
    var status: Int32
    var stdout: CapturedText
    var stderr: CapturedText
    var terminated: Bool
}

private final class ShellJob: Sendable {
    private struct State {
        var exitObserved = false
        var reaped = false
        var terminateRequested = false
        var terminated = false
    }

    private let pid: pid_t
    private let outFD: Int32
    private let errFD: Int32
    private let killGrace: TimeInterval
    private let state = Mutex(State())

    private init(pid: pid_t, outFD: Int32, errFD: Int32, killGrace: TimeInterval) {
        self.pid = pid
        self.outFD = outFD
        self.errFD = errFD
        self.killGrace = killGrace
    }

    static func spawn(command: String, directory: String, shell: String, killGrace: TimeInterval) throws -> ShellJob {
        var out: [Int32] = [-1, -1]
        var err: [Int32] = [-1, -1]
        guard pipe(&out) == 0 else { throw DeviceProviderError.failed("The command could not be started.") }
        guard pipe(&err) == 0 else {
            close(out[0])
            close(out[1])
            throw DeviceProviderError.failed("The command could not be started.")
        }
        for descriptor in out + err { _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC) }

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, out[1], 1)
        posix_spawn_file_actions_adddup2(&actions, err[1], 2)
        posix_spawn_file_actions_addchdir_np(&actions, directory)
        var defaults = sigset_t()
        sigfillset(&defaults)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var blocked = sigset_t()
        sigemptyset(&blocked)
        posix_spawnattr_setsigmask(&attributes, &blocked)
        posix_spawnattr_setpgroup(&attributes, 0)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT))

        let argv: [UnsafeMutablePointer<CChar>?] = [shell, "-l", "-c", command].map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for pointer in argv { free(pointer) }
            for pointer in envp { free(pointer) }
        }
        var pid: pid_t = 0
        let code = posix_spawn(&pid, shell, &actions, &attributes, argv, envp)
        close(out[1])
        close(err[1])
        guard code == 0 else {
            close(out[0])
            close(err[0])
            throw DeviceProviderError.failed("The command could not be started: \(String(cString: strerror(code))).")
        }
        return ShellJob(pid: pid, outFD: out[0], errFD: err[0], killGrace: killGrace)
    }

    @discardableResult
    func terminate() -> Bool {
        let signaled = state.withLock { current -> Bool in
            guard !current.reaped, !current.terminateRequested else { return false }
            current.terminateRequested = true
            guard kill(-pid, SIGTERM) == 0 else { return false }
            if !current.exitObserved { current.terminated = true }
            return true
        }
        guard signaled else { return false }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + killGrace) { [self] in
            state.withLock { current in
                if !current.reaped { _ = kill(-pid, SIGKILL) }
            }
        }
        return true
    }

    func finish(timeout: Duration, captureLimit: Int) async -> ShellRunRecord {
        let timer = Task { [self] in
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled { terminate() }
        }
        let finished = await withCheckedContinuation { (continuation: CheckedContinuation<ShellExit, Never>) in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                continuation.resume(returning: collect(captureLimit: captureLimit))
            }
        }
        timer.cancel()
        return ShellRunRecord(
            exitCode: finished.terminated ? nil : Self.exitCode(of: finished.status),
            stdout: finished.stdout, stderr: finished.stderr, timedOut: finished.terminated
        )
    }

    private func collect(captureLimit: Int) -> ShellExit {
        let keep = captureLimit + DeviceTextLimit.slack
        let out = OutputCollector(keep: keep)
        let err = OutputCollector(keep: keep)
        let group = DispatchGroup()
        for (descriptor, collector) in [(outFD, out), (errFD, err)] {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                drain(descriptor, into: collector)
                group.leave()
            }
        }
        let status = awaitExit()
        group.wait()
        close(outFD)
        close(errFD)
        return ShellExit(
            status: status,
            stdout: TextCap.capture(out.bytes, totalBytes: out.total, limit: captureLimit),
            stderr: TextCap.capture(err.bytes, totalBytes: err.total, limit: captureLimit),
            terminated: state.withLock { $0.terminated }
        )
    }

    private func drain(_ descriptor: Int32, into collector: OutputCollector) {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            var poller = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&poller, 1, 50)
            if ready < 0 {
                if errno == EINTR { continue }
                return
            }
            if ready == 0 {
                if state.withLock({ $0.exitObserved }) { return }
                continue
            }
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                collector.append(buffer, count: count)
            } else if count < 0, errno == EINTR || errno == EAGAIN {
                continue
            } else {
                return
            }
        }
    }

    private func awaitExit() -> Int32 {
        var info = siginfo_t()
        while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) != 0, errno == EINTR {}
        state.withLock { current in
            current.exitObserved = true
            if current.terminateRequested { _ = kill(-pid, SIGKILL) }
        }
        var status: Int32 = 0
        state.withLock { current in
            while waitpid(pid, &status, 0) < 0, errno == EINTR {}
            current.reaped = true
        }
        return status
    }

    private static func exitCode(of status: Int32) -> Int {
        let signal = status & 0x7f
        return signal == 0 ? Int((status >> 8) & 0xff) : 128 + Int(signal)
    }
}
#endif
