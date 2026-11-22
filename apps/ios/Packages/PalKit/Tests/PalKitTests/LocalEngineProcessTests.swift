#if os(macOS)
import Foundation
import PalLocalEngine
import PalProcess
import Synchronization
import Testing

private final class Lines: Sendable {
    private let storage = Mutex<[EngineOutputLine]>([])
    var all: [EngineOutputLine] { storage.withLock { $0 } }
    func add(_ line: EngineOutputLine) { storage.withLock { $0.append(line) } }
}

@Suite("Local engine processes")
struct LocalEngineProcessTests {
    private func command(_ script: String, input: Data? = nil) -> EngineCommand {
        EngineCommand(
            executable: "/bin/sh", arguments: ["-c", script], environment: ["PATH": "/usr/bin:/bin", "ONLY": "mine"],
            workingDirectory: NSTemporaryDirectory(), standardInput: input
        )
    }

    @Test func outputStreamsLineByLineWithErrorsMarked() async {
        let lines = Lines()
        let outcome = await PosixEngineProcessRunner().run(command("echo one; echo two >&2; printf 'partial'; exit 3"), onLine: lines.add)
        #expect(outcome == .exited(code: 3))
        #expect(lines.all.filter { !$0.isError }.map(\.text) == ["one", "partial"])
        #expect(lines.all.filter(\.isError).map(\.text) == ["two"])
    }

    @Test func standardInputReachesTheChildAndTheChildGetsOnlyTheGivenEnvironment() async {
        let lines = Lines()
        let token = "stdin-secret-value"
        let script = "read value; echo \"got:$value\"; echo \"only:${ONLY}:${HOME:-unset}\""
        let outcome = await PosixEngineProcessRunner().run(command(script, input: Data((token + "\n").utf8)), onLine: lines.add)
        #expect(outcome == .exited(code: 0))
        #expect(lines.all.map(\.text) == ["got:\(token)", "only:mine:unset"])
    }

    @Test func aChildThatNeverReadsItsInputDoesNotKillTheApp() async {
        let outcome = await PosixEngineProcessRunner().run(command("exit 0", input: Data("ignored\n".utf8)), onLine: { _ in })
        #expect(outcome == .exited(code: 0))
    }

    @Test func aMissingProgramIsALaunchFailure() async {
        let missing = EngineCommand(executable: "/nonexistent/hermes", arguments: [], environment: [:], workingDirectory: NSTemporaryDirectory())
        #expect(await PosixEngineProcessRunner().run(missing, onLine: { _ in }) == .launchFailed)
    }

    @Test func cancellingKillsTheWholeProcessGroupIncludingGrandchildren() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appending(path: "pal-grandchild-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let runner = PosixEngineProcessRunner(killGrace: 1)
        let task = Task { await runner.run(command("sleep 60 & echo $! > '\(pidFile.path)'; wait"), onLine: { _ in }) }
        var childPID: Int32?
        for _ in 0..<100 {
            if let text = try? String(contentsOf: pidFile, encoding: .utf8), let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                childPID = pid
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let pid = try #require(childPID)
        task.cancel()
        #expect(await task.value == .cancelled)
        var alive = true
        for _ in 0..<60 {
            alive = kill(pid, 0) == 0
            if !alive { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(!alive, "the grandchild must not outlive a cancelled install")
    }

    @Test func aTaskCancelledBeforeStartingNeverSpawns() async {
        let marker = FileManager.default.temporaryDirectory.appending(path: "pal-never-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let task = Task {
            try? await Task.sleep(for: .seconds(5))
            return await PosixEngineProcessRunner().run(command("touch '\(marker.path)'"), onLine: { _ in })
        }
        task.cancel()
        #expect(await task.value == .cancelled)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func tooMuchStandardInputIsRefusedBeforeSpawning() async {
        let big = Data(repeating: 65, count: ProcessJob.maxStandardInput + 1)
        #expect(await PosixEngineProcessRunner().run(command("cat >/dev/null", input: big), onLine: { _ in }) == .launchFailed)
    }
}
#endif
