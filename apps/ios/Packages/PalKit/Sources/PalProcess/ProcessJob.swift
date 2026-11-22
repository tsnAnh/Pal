#if os(macOS)
import Foundation
import Synchronization

public struct ProcessSpec: Sendable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: String
    public var standardInput: Data?

    public init(
        executable: String,
        arguments: [String] = [],
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

public enum ProcessStream: Sendable, Equatable {
    case standardOutput
    case standardError
}

public enum ProcessLaunchError: Error, Sendable, Equatable {
    case pipe
    case standardInputTooLarge
    case spawn(Int32)
}

public struct ProcessExit: Sendable, Equatable {
    public let waitStatus: Int32
    public let terminated: Bool

    public var exitCode: Int? {
        terminated ? nil : Self.exitCode(ofWaitStatus: waitStatus)
    }

    public static func exitCode(ofWaitStatus status: Int32) -> Int {
        let signal = status & 0x7f
        return signal == 0 ? Int((status >> 8) & 0xff) : 128 + Int(signal)
    }
}

private struct Pipes {
    private let out: [Int32]
    private let err: [Int32]
    private let input: [Int32]

    var outRead: Int32 { out[0] }
    var outWrite: Int32 { out[1] }
    var errRead: Int32 { err[0] }
    var errWrite: Int32 { err[1] }
    var inputRead: Int32 { input[0] }
    var inputWrite: Int32 { input[1] }

    static func open(withInput: Bool) throws(ProcessLaunchError) -> Pipes {
        var out: [Int32] = [-1, -1]
        var err: [Int32] = [-1, -1]
        var input: [Int32] = [-1, -1]
        guard pipe(&out) == 0 else { throw .pipe }
        guard pipe(&err) == 0 else {
            closeAll(out)
            throw .pipe
        }
        if withInput, pipe(&input) != 0 {
            closeAll(out + err)
            throw .pipe
        }
        for descriptor in out + err + input where descriptor >= 0 { _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC) }
        return Pipes(out: out, err: err, input: input)
    }

    func closeChildEnds() {
        close(outWrite)
        close(errWrite)
        if inputRead >= 0 { close(inputRead) }
    }

    func closeParentEnds() {
        close(outRead)
        close(errRead)
        if inputWrite >= 0 { close(inputWrite) }
    }

    private static func closeAll(_ descriptors: [Int32]) {
        for descriptor in descriptors where descriptor >= 0 { close(descriptor) }
    }
}

public final class ProcessJob: Sendable {
    public typealias OutputSink = @Sendable (ProcessStream, [UInt8]) -> Void

    public static let maxStandardInput = 16 * 1024

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

    public static func spawn(_ spec: ProcessSpec, killGrace: TimeInterval) throws(ProcessLaunchError) -> ProcessJob {
        if let input = spec.standardInput, input.count > maxStandardInput { throw .standardInputTooLarge }
        let pipes = try Pipes.open(withInput: spec.standardInput != nil)
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        configure(&actions, &attributes, spec: spec, pipes: pipes)

        let argv: [UnsafeMutablePointer<CChar>?] = ([spec.executable] + spec.arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = spec.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for pointer in argv { free(pointer) }
            for pointer in envp { free(pointer) }
        }
        var pid: pid_t = 0
        let code = posix_spawn(&pid, spec.executable, &actions, &attributes, argv, envp)
        pipes.closeChildEnds()
        guard code == 0 else {
            pipes.closeParentEnds()
            throw .spawn(code)
        }
        if let data = spec.standardInput { feed(data, to: pipes.inputWrite) }
        return ProcessJob(pid: pid, outFD: pipes.outRead, errFD: pipes.errRead, killGrace: killGrace)
    }

    private static func configure(
        _ actions: inout posix_spawn_file_actions_t?, _ attributes: inout posix_spawnattr_t?, spec: ProcessSpec, pipes: Pipes
    ) {
        if spec.standardInput != nil {
            posix_spawn_file_actions_adddup2(&actions, pipes.inputRead, 0)
        } else {
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        }
        posix_spawn_file_actions_adddup2(&actions, pipes.outWrite, 1)
        posix_spawn_file_actions_adddup2(&actions, pipes.errWrite, 2)
        posix_spawn_file_actions_addchdir_np(&actions, spec.workingDirectory)
        var defaults = sigset_t()
        sigfillset(&defaults)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var blocked = sigset_t()
        sigemptyset(&blocked)
        posix_spawnattr_setsigmask(&attributes, &blocked)
        posix_spawnattr_setpgroup(&attributes, 0)
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT
        posix_spawnattr_setflags(&attributes, Int16(flags))
    }

    private static func feed(_ data: Data, to descriptor: Int32) {
        _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(descriptor, raw.baseAddress! + offset, raw.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    break
                }
            }
        }
        close(descriptor)
    }

    @discardableResult
    public func terminate() -> Bool {
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

    public func finish(timeout: Duration?, onOutput: @escaping OutputSink) async -> ProcessExit {
        let timer = timeout.map { limit in
            Task { [self] in
                try? await Task.sleep(for: limit)
                if !Task.isCancelled { terminate() }
            }
        }
        let finished = await withCheckedContinuation { (continuation: CheckedContinuation<ProcessExit, Never>) in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                continuation.resume(returning: collect(onOutput: onOutput))
            }
        }
        timer?.cancel()
        return finished
    }

    private func collect(onOutput: @escaping OutputSink) -> ProcessExit {
        let group = DispatchGroup()
        for (descriptor, stream) in [(outFD, ProcessStream.standardOutput), (errFD, .standardError)] {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                drain(descriptor, stream: stream, onOutput: onOutput)
                group.leave()
            }
        }
        let status = awaitExit()
        group.wait()
        close(outFD)
        close(errFD)
        return ProcessExit(waitStatus: status, terminated: state.withLock { $0.terminated })
    }

    private func drain(_ descriptor: Int32, stream: ProcessStream, onOutput: OutputSink) {
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
                onOutput(stream, Array(buffer[0..<count]))
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
}
#endif
