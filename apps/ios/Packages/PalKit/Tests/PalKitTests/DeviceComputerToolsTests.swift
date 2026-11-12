import Foundation
import PalDevice
import PalProtocol
import Synchronization
import Testing

private final class FakeComputer: ShellProviding, FilesProviding {
    struct ShellCall: Equatable {
        var command: String
        var directory: String?
        var timeout: Duration
        var captureLimit: Int
    }

    struct WriteCall: Equatable {
        var path: String
        var content: String
        var append: Bool
        var createDirs: Bool
    }

    private struct Recorded {
        var shell: [ShellCall] = []
        var reads: [String] = []
        var lists: [(String, Int)] = []
        var writes: [WriteCall] = []
    }

    private let recorded = Mutex(Recorded())
    let shellRecord: ShellRunRecord
    let readRecord: FileReadRecord
    let listRecord: FileListRecord
    let failure: DeviceProviderError?

    init(
        shell: ShellRunRecord = ShellRunRecord(exitCode: 0),
        read: FileReadRecord = FileReadRecord(path: "/x", content: CapturedText(), sizeBytes: 0),
        list: FileListRecord = FileListRecord(path: "/x", entries: []),
        failure: DeviceProviderError? = nil
    ) {
        shellRecord = shell
        readRecord = read
        listRecord = list
        self.failure = failure
    }

    var shellCalls: [ShellCall] { recorded.withLock { $0.shell } }
    var readPaths: [String] { recorded.withLock { $0.reads } }
    var listCalls: [(String, Int)] { recorded.withLock { $0.lists } }
    var writeCalls: [WriteCall] { recorded.withLock { $0.writes } }
    var untouched: Bool { shellCalls.isEmpty && readPaths.isEmpty && listCalls.isEmpty && writeCalls.isEmpty }

    func run(command: String, workingDirectory: String?, timeout: Duration, captureLimit: Int) async throws -> ShellRunRecord {
        recorded.withLock { $0.shell.append(ShellCall(command: command, directory: workingDirectory, timeout: timeout, captureLimit: captureLimit)) }
        if let failure { throw failure }
        return shellRecord
    }

    func read(path: String, captureLimit: Int) async throws -> FileReadRecord {
        recorded.withLock { $0.reads.append(path) }
        if let failure { throw failure }
        return readRecord
    }

    func list(path: String, limit: Int) async throws -> FileListRecord {
        recorded.withLock { $0.lists.append((path, limit)) }
        if let failure { throw failure }
        return listRecord
    }

    func write(path: String, content: String, append: Bool, createDirs: Bool) async throws -> FileWriteRecord {
        recorded.withLock { $0.writes.append(WriteCall(path: path, content: content, append: append, createDirs: createDirs)) }
        if let failure { throw failure }
        return FileWriteRecord(path: path, bytesWritten: content.utf8.count)
    }
}

private struct UnlistedConnectorsAPI: DeviceConnectorsAPI {
    func list() async throws -> DeviceConnectorsResult { DeviceConnectorsResult(deviceID: "device-1234", connectors: []) }

    func set(_ id: DeviceConnectorID, state: DeviceConnectorState?, osPermission: DeviceOSPermission?) async throws -> DeviceConnectorsResult {
        DeviceConnectorsResult(deviceID: "device-1234", connectors: [])
    }
}

private struct ComputerRig {
    let executor: DeviceToolExecutor
    let computer: FakeComputer
    let api: FakeConnectorsAPI
    let consent: FakeConsent
    let permissions: FakePermissions
}

private func computerRig(
    _ states: [DeviceConnectorID: DeviceConnectorState] = [.shell: .allowed, .files: .allowed],
    computer: FakeComputer = FakeComputer(),
    providers: Bool = true,
    consent: Bool = true
) async -> ComputerRig {
    let api = FakeConnectorsAPI(states)
    let ledger = ConnectorLedger(api: api)
    _ = try? await ledger.refresh()
    let fakeConsent = FakeConsent(consent)
    let permissions = FakePermissions()
    let executor = DeviceToolExecutor(
        providers: providers ? DeviceProviders(shell: computer, files: computer) : DeviceProviders(),
        permissions: permissions, ledger: ledger, consent: fakeConsent,
        environment: DeviceToolEnvironment(timeZone: { TimeZone(secondsFromGMT: 7 * 3600)! }, deadlineMargin: .zero)
    )
    return ComputerRig(executor: executor, computer: computer, api: api, consent: fakeConsent, permissions: permissions)
}

private func call(_ action: String, args: JSONValue = [:], needsConsent: Bool = false, deadline: Int = 30) -> DeviceToolRequest {
    DeviceToolRequest(
        requestID: "req-00000001", action: action, connector: DeviceToolAction(rawValue: action)?.connector.rawValue ?? "",
        args: args, needsConsent: needsConsent, profile: "default", deadlineSeconds: deadline
    )
}

private func failed(_ outcome: DeviceToolOutcome) -> (DeviceToolErrorCode, String)? {
    if case .failure(let code, let message) = outcome { return (code, message) }
    return nil
}

private func succeeded(_ outcome: DeviceToolOutcome) -> JSONValue? {
    if case .success(let value) = outcome { return value }
    return nil
}

private let validCalls: [(String, JSONValue)] = [
    ("shell.run", ["command": "echo hi"]),
    ("files.read", ["path": "/tmp/a.txt"]),
    ("files.list", ["path": "/tmp"]),
    ("files.write", ["path": "/tmp/a.txt", "content": "x"]),
]

private let invalidCalls: [(String, JSONValue)] = [
    ("shell.run", [:]),
    ("shell.run", ["command": ""]),
    ("shell.run", ["command": "   \n"]),
    ("shell.run", ["command": .string(String(repeating: "a", count: 8001))]),
    ("shell.run", ["command": "echo hi", "timeout_seconds": 0]),
    ("shell.run", ["command": "echo hi", "timeout_seconds": 301]),
    ("shell.run", ["command": "echo hi", "timeout_seconds": "ten"]),
    ("shell.run", ["command": "echo hi", "cwd": "projects/app"]),
    ("shell.run", ["command": "echo hi", "cwd": ""]),
    ("files.read", [:]),
    ("files.read", ["path": "notes.txt"]),
    ("files.read", ["path": ""]),
    ("files.read", ["path": "~bob/notes.txt"]),
    ("files.list", ["path": "."]),
    ("files.list", ["path": "Documents"]),
    ("files.write", ["path": "notes.txt", "content": "x"]),
    ("files.write", ["path": "/tmp/a.txt"]),
    ("files.write", ["path": "/tmp/a.txt", "content": "x", "append": "yes"]),
]

@Suite("Computer tools on the executor")
struct DeviceComputerExecutorTests {
    @Test(arguments: validCalls)
    func aDeviceWithoutTheProvidersAnswersUnsupportedInNeutralWords(action: String, args: JSONValue) async {
        let rig = await computerRig(providers: false)
        let outcome = await rig.executor.execute(call(action, args: args))
        let refusal = failed(outcome)
        #expect(refusal?.0 == .unsupported)
        #expect(refusal?.1.contains(action) == true)
        #expect(refusal?.1.localizedCaseInsensitiveContains("iphone") == false)
    }

    @Test(arguments: invalidCalls)
    func invalidArgumentsAreRefusedBeforeAnyProviderRuns(action: String, args: JSONValue) async {
        let rig = await computerRig()
        let outcome = await rig.executor.execute(call(action, args: args))
        #expect(failed(outcome)?.0 == .invalidArgs)
        #expect(rig.computer.untouched)
    }

    @Test(arguments: validCalls)
    func shellAndFilesAnswerWithNoSwitchState(action: String, args: JSONValue) async {
        let rig = await computerRig([:])
        let outcome = await rig.executor.execute(call(action, args: args))
        #expect(succeeded(outcome) != nil)
        #expect(!rig.computer.untouched)
    }

    @Test(arguments: validCalls)
    func shellAndFilesNeverAskConsentOrWriteSwitchState(action: String, args: JSONValue) async {
        let rig = await computerRig([.shell: .off, .files: .ask], consent: false)
        let outcome = await rig.executor.execute(call(action, args: args, needsConsent: true))
        #expect(succeeded(outcome) != nil)
        #expect(rig.consent.asked.withLock { $0 }.isEmpty)
        #expect(rig.api.sets.isEmpty)
    }

    @Test(arguments: validCalls)
    func shellAndFilesWorkWhenTheServerNeverListedThem(action: String, args: JSONValue) async {
        let ledger = ConnectorLedger(api: UnlistedConnectorsAPI())
        _ = try? await ledger.refresh()
        let computer = FakeComputer()
        let executor = DeviceToolExecutor(
            providers: DeviceProviders(shell: computer, files: computer), permissions: FakePermissions(), ledger: ledger, consent: FakeConsent(false)
        )
        #expect(succeeded(await executor.execute(call(action, args: args))) != nil)
    }

    @Test func gatewayEntriesForShellAndFilesWithUnknownFieldsDecode() throws {
        let payload: JSONValue = [
            "device_id": "device-1234",
            "connectors": [
                ["id": "shell", "title": "Run commands", "subtitle": "x", "state": "allowed", "always_on": true],
                ["id": "files", "title": "Files", "subtitle": "x", "state": "allowed", "always_on": true, "future": 1],
                ["id": "clipboard", "title": "Clipboard", "subtitle": "x", "state": "off"],
            ],
        ]
        let result = try payload.decoded(as: DeviceConnectorsResult.self)
        #expect(result.connectors.map(\.id) == [.shell, .files, .clipboard])
    }

    @Test func noOSPermissionIsEverRequested() async {
        let rig = await computerRig()
        for (action, args) in validCalls { _ = await rig.executor.execute(call(action, args: args)) }
        #expect(rig.permissions.requested.withLock { $0 }.isEmpty)
        #expect(rig.computer.shellCalls.count == 1 && rig.computer.readPaths.count == 1)
    }

    @Test func aShellResultCarriesEveryContractField() async throws {
        let computer = FakeComputer(shell: ShellRunRecord(exitCode: 3, stdout: CapturedText(text: "out\n"), stderr: CapturedText(text: "err\n")))
        let rig = await computerRig(computer: computer)
        let value = try #require(succeeded(await rig.executor.execute(call("shell.run", args: ["command": "false"]))))
        #expect(value["exit_code"]?.intValue == 3)
        #expect(value["stdout"]?.stringValue == "out\n")
        #expect(value["stderr"]?.stringValue == "err\n")
        #expect(value["timed_out"]?.boolValue == false)
        #expect(value["truncated"]?.boolValue == false)
    }

    @Test func aTimedOutShellResultHasANullExitCodeAndStillSucceeds() async throws {
        let computer = FakeComputer(shell: ShellRunRecord(exitCode: nil, stdout: CapturedText(text: "partial"), timedOut: true))
        let rig = await computerRig(computer: computer)
        let value = try #require(succeeded(await rig.executor.execute(call("shell.run", args: ["command": "sleep 99"]))))
        #expect(value["exit_code"] == JSONValue.null)
        #expect(value["timed_out"]?.boolValue == true)
        #expect(value["stdout"]?.stringValue == "partial")
    }

    @Test func theShellGetsTheResolvedDirectoryTheDefaultTimeoutAndTheOutputCap() async {
        let rig = await computerRig()
        _ = await rig.executor.execute(call("shell.run", args: ["command": "ls", "cwd": "~/projects"], deadline: 100))
        _ = await rig.executor.execute(call("shell.run", args: ["command": "ls"], deadline: 100))
        let calls = rig.computer.shellCalls
        #expect(calls.map(\.directory) == [NSHomeDirectory() + "/projects", nil])
        #expect(calls.map(\.timeout) == [.seconds(30), .seconds(30)])
        #expect(calls.allSatisfy { $0.captureLimit == DeviceTextLimit.output })
    }

    @Test func theShellTimeoutNeverOutlivesTheRequestDeadline() async {
        let rig = await computerRig()
        _ = await rig.executor.execute(call("shell.run", args: ["command": "sleep 99", "timeout_seconds": 300], deadline: 10))
        _ = await rig.executor.execute(call("shell.run", args: ["command": "sleep 99", "timeout_seconds": 5], deadline: 1))
        let timeouts = rig.computer.shellCalls.map(\.timeout)
        #expect(timeouts[0] == .seconds(7))
        #expect(timeouts[1] == .milliseconds(500))
    }

    @Test func oversizedShellOutputIsCutAtAWholeCharacterWithTheMarker() async throws {
        let computer = FakeComputer(shell: ShellRunRecord(exitCode: 0, stdout: CapturedText(text: "a" + String(repeating: "€", count: 20_000))))
        let rig = await computerRig(computer: computer)
        let value = try #require(succeeded(await rig.executor.execute(call("shell.run", args: ["command": "yes"]))))
        let stdout = try #require(value["stdout"]?.stringValue)
        let marker = "\n…[truncated 10851 bytes omitted]"
        #expect(stdout.hasSuffix(marker))
        let kept = String(stdout.dropLast(marker.count))
        #expect(kept.utf8.count == 49_150)
        #expect(kept.hasPrefix("a€") && !kept.contains("\u{FFFD}"))
        #expect(value["truncated"]?.boolValue == true)
        #expect(value["stderr"]?.stringValue == "")
    }

    @Test func omittedBytesTheProviderReportsBecomeTheMarker() async throws {
        let computer = FakeComputer(shell: ShellRunRecord(exitCode: 0, stdout: CapturedText(text: "x", omittedBytes: 500), stderr: CapturedText(text: "fine")))
        let rig = await computerRig(computer: computer)
        let value = try #require(succeeded(await rig.executor.execute(call("shell.run", args: ["command": "yes"]))))
        #expect(value["stdout"]?.stringValue == "x\n…[truncated 500 bytes omitted]")
        #expect(value["stderr"]?.stringValue == "fine")
        #expect(value["truncated"]?.boolValue == true)
    }

    @Test func aTruncatedResultIsNeverEmpty() async throws {
        let computer = FakeComputer(shell: ShellRunRecord(exitCode: 0, stdout: CapturedText(text: "", omittedBytes: 7)))
        let rig = await computerRig(computer: computer)
        let value = try #require(succeeded(await rig.executor.execute(call("shell.run", args: ["command": "yes"]))))
        #expect(value["stdout"]?.stringValue == "\n…[truncated 7 bytes omitted]")
    }

    @Test func fileContentIsCappedAtNinetySixKilobytes() async throws {
        let computer = FakeComputer(read: FileReadRecord(path: "/tmp/big.txt", content: CapturedText(text: String(repeating: "b", count: 100_000)), sizeBytes: 100_000))
        let rig = await computerRig(computer: computer)
        let value = try #require(succeeded(await rig.executor.execute(call("files.read", args: ["path": "/tmp/big.txt"]))))
        let content = try #require(value["content"]?.stringValue)
        #expect(content.hasSuffix("\n…[truncated 1696 bytes omitted]"))
        #expect(content.utf8.count == 98_304 + "\n…[truncated 1696 bytes omitted]".utf8.count)
        #expect(value["truncated"]?.boolValue == true)
        #expect(value["size_bytes"]?.intValue == 100_000)
        #expect(value["path"]?.stringValue == "/tmp/big.txt")
    }

    @Test func aSmallFileIsReturnedWholeWithTheResolvedPath() async throws {
        let computer = FakeComputer(read: FileReadRecord(path: NSHomeDirectory() + "/n.txt", content: CapturedText(text: "hello"), sizeBytes: 5))
        let rig = await computerRig(computer: computer)
        let value = try #require(succeeded(await rig.executor.execute(call("files.read", args: ["path": "~/n.txt"]))))
        #expect(rig.computer.readPaths == [NSHomeDirectory() + "/n.txt"])
        #expect(value["content"]?.stringValue == "hello")
        #expect(value["truncated"]?.boolValue == false)
    }

    @Test func aListingCarriesKindsSizesAndIsoTimes() async throws {
        let computer = FakeComputer(list: FileListRecord(path: "/tmp/d", entries: [
            FileEntryRecord(name: "a.txt", kind: .file, sizeBytes: 12, modified: Date(timeIntervalSince1970: 1_800_000_000)),
            FileEntryRecord(name: "sub", kind: .directory),
            FileEntryRecord(name: "link", kind: .symlink),
            FileEntryRecord(name: "pipe", kind: .other),
        ]))
        let rig = await computerRig(computer: computer)
        let value = try #require(succeeded(await rig.executor.execute(call("files.list", args: ["path": "/tmp/d"]))))
        let entries = try #require(value["entries"]?.arrayValue)
        #expect(entries.compactMap { $0["kind"]?.stringValue } == ["file", "directory", "symlink", "other"])
        #expect(entries[0]["size_bytes"]?.intValue == 12)
        #expect(entries[0]["modified_at"]?.stringValue?.hasSuffix("+07:00") == true)
        #expect(entries[1]["size_bytes"] == nil)
        #expect(value["truncated"]?.boolValue == false)
    }

    @Test(arguments: [(JSONValue.int(9999), 500), (.int(0), 1), (.int(-5), 1), (.int(25), 25), (.null, 200)])
    func theListingLimitIsClampedToTheContractRange(limit: JSONValue, expected: Int) async {
        let rig = await computerRig()
        _ = await rig.executor.execute(call("files.list", args: ["path": "/tmp", "limit": limit]))
        #expect(rig.computer.listCalls.map(\.1) == [expected])
    }

    @Test func aListingLongerThanTheLimitIsCutAndFlaggedTruncated() async throws {
        let computer = FakeComputer(list: FileListRecord(path: "/tmp", entries: (0..<5).map { FileEntryRecord(name: "f\($0)", kind: .file) }))
        let rig = await computerRig(computer: computer)
        let value = try #require(succeeded(await rig.executor.execute(call("files.list", args: ["path": "/tmp", "limit": 2]))))
        #expect(value["entries"]?.arrayValue?.count == 2)
        #expect(value["truncated"]?.boolValue == true)
    }

    @Test func aWriteDefaultsToReplaceWithoutCreatingFolders() async throws {
        let rig = await computerRig()
        let value = try #require(succeeded(await rig.executor.execute(call("files.write", args: ["path": "~/out/a.txt", "content": "héllo"]))))
        #expect(rig.computer.writeCalls == [.init(path: NSHomeDirectory() + "/out/a.txt", content: "héllo", append: false, createDirs: false)])
        #expect(value["bytes_written"]?.intValue == 6)
        #expect(value["path"]?.stringValue == NSHomeDirectory() + "/out/a.txt")
    }

    @Test func appendAndCreateDirsAreForwarded() async {
        let rig = await computerRig()
        _ = await rig.executor.execute(call("files.write", args: ["path": "/tmp/a/b.txt", "content": "x", "append": true, "create_dirs": true]))
        #expect(rig.computer.writeCalls == [.init(path: "/tmp/a/b.txt", content: "x", append: true, createDirs: true)])
    }

    @Test(arguments: [
        (DeviceProviderError.notFound, DeviceToolErrorCode.notFound),
        (.accessDenied("/secret/x"), .permissionDenied),
        (.permissionDenied, .permissionDenied),
        (.invalidArgs("bad"), .invalidArgs),
        (.failed("boom"), .failed),
    ])
    func providerFailuresMapToTheContractCodes(error: DeviceProviderError, code: DeviceToolErrorCode) async {
        for (action, args) in validCalls {
            let rig = await computerRig(computer: FakeComputer(failure: error))
            #expect(failed(await rig.executor.execute(call(action, args: args)))?.0 == code)
        }
    }

    @Test func aPermissionRefusalNamesThePath() async {
        let rig = await computerRig(computer: FakeComputer(failure: .accessDenied("/secret/x")))
        let refusal = failed(await rig.executor.execute(call("files.read", args: ["path": "/secret/x"])))
        #expect(refusal?.0 == .permissionDenied)
        #expect(refusal?.1.contains("/secret/x") == true)
    }

    @Test func shellAndFilesCarryNoSwitchWording() {
        for id in [DeviceConnectorID.shell, .files] {
            #expect(DeviceConnectorDefaults.warning(for: id) == nil)
            #expect(id.isAlwaysOn)
            #expect(!DeviceConnectorDefaults.entry(for: id).title.contains("Run commands"))
        }
        #expect(DeviceConnectorDefaults.warning(for: .calendar) == nil)
        #expect(!DeviceConnectorID.calendar.isAlwaysOn && !DeviceConnectorID.input.isAlwaysOn)
    }

    @Test func theActionsBelongToTheirConnectors() {
        #expect(DeviceToolAction.shellRun.connector == .shell)
        #expect([DeviceToolAction.filesRead, .filesList, .filesWrite].allSatisfy { $0.connector == .files })
        #expect(!DeviceConnectorID.shell.needsOSPermission && !DeviceConnectorID.files.needsOSPermission)
        #expect(DeviceConnectorID.calendar.needsOSPermission)
    }
}

@Suite("Device paths and text caps")
struct DevicePathAndCapTests {
    @Test func tildeExpandsToTheHome() throws {
        #expect(try DevicePath.resolve("~", home: "/Users/sam") == "/Users/sam")
        #expect(try DevicePath.resolve("~/Documents/a.txt", home: "/Users/sam") == "/Users/sam/Documents/a.txt")
        #expect(try DevicePath.resolve("/etc/hosts", home: "/Users/sam") == "/etc/hosts")
        #expect(try DevicePath.resolve("~/a/../b", home: "/Users/sam") == "/Users/sam/b")
    }

    @Test(arguments: ["", "a.txt", "./a.txt", "../a", "~sam/a", "Documents/a.txt", "a\u{0}b", "/tmp/a\u{0}b"])
    func everythingElseIsInvalid(raw: String) {
        #expect(throws: DeviceProviderError.self) { try DevicePath.resolve(raw, home: "/Users/sam") }
    }

    @Test func textWithinTheLimitIsUntouched() {
        let capped = TextCap.finish(CapturedText(text: "hello"), limit: 5)
        #expect(capped.text == "hello" && !capped.truncated)
    }

    @Test func aCutNeverSplitsAScalar() {
        let capture = TextCap.capture(Array("a€€€".utf8), totalBytes: 10, limit: 5)
        #expect(capture.text == "a€")
        #expect(capture.omittedBytes == 6)
        let finished = TextCap.finish(CapturedText(text: "a€€€"), limit: 5)
        #expect(finished.text == "a€\n…[truncated 6 bytes omitted]")
        #expect(finished.truncated)
    }
}

#if os(macOS)
@Suite("Real shell provider", .serialized)
struct SystemShellTests {
    private let shell = SystemShell()

    private func run(_ command: String, cwd: String? = nil, timeout: Duration = .seconds(20), limit: Int = DeviceTextLimit.output) async throws -> ShellRunRecord {
        try await shell.run(command: command, workingDirectory: cwd, timeout: timeout, captureLimit: limit)
    }

    private func scratch() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("shell-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }

    private func waitUntilGone(_ pid: pid_t) async -> Bool {
        for _ in 0..<40 {
            if kill(pid, 0) != 0, errno == ESRCH { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    @Test func echoPrintsAndExitsZero() async throws {
        let record = try await run("echo hi")
        #expect(record.exitCode == 0)
        #expect(record.stdout.text.hasSuffix("hi\n"))
        #expect(!record.timedOut)
    }

    @Test func theExitCodeIsReported() async throws {
        let record = try await run("exit 3")
        #expect(record.exitCode == 3)
        #expect(!record.timedOut)
    }

    @Test func stdoutAndStderrStaySeparate() async throws {
        let record = try await run("echo out; echo err >&2")
        #expect(record.stdout.text.hasSuffix("out\n") && !record.stdout.text.contains("err"))
        #expect(record.stderr.text == "err\n")
    }

    @Test func stdinIsEmptySoReadersFinish() async throws {
        let record = try await run("cat; echo done")
        #expect(record.exitCode == 0)
        #expect(record.stdout.text.hasSuffix("done\n"))
    }

    @Test func theCommandLeadsItsOwnProcessGroup() async throws {
        let record = try await run("echo $$ $(ps -o pgid= -p $$)")
        let numbers = record.stdout.text.split(whereSeparator: \.isWhitespace).suffix(2)
        #expect(numbers.count == 2 && numbers.first == numbers.last)
    }

    @Test func theWorkingDirectoryIsHonored() async throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = try await run("pwd -P", cwd: directory.path)
        #expect(record.stdout.text.hasSuffix(directory.path + "\n"))
    }

    @Test func theDefaultDirectoryIsTheHome() async throws {
        let record = try await run("pwd -P")
        let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path
        #expect(record.stdout.text.hasSuffix(home + "\n"))
    }

    @Test func aMissingWorkingDirectoryIsNotFound() async {
        await #expect(throws: DeviceProviderError.notFound) { try await run("echo hi", cwd: "/no/such/folder-\(UUID().uuidString)") }
    }

    @Test func aRelativeWorkingDirectoryIsInvalid() async {
        await #expect(throws: DeviceProviderError.self) { try await run("echo hi", cwd: "relative/dir") }
    }

    @Test func aFileAsWorkingDirectoryIsInvalid() async {
        await #expect(throws: DeviceProviderError.self) { try await run("echo hi", cwd: "/etc/hosts") }
    }

    @Test func aSlowCommandIsKilledAndItsProcessesAreGone() async throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let shellPID = directory.appendingPathComponent("shell.pid").path
        let childPID = directory.appendingPathComponent("child.pid").path
        let started = ContinuousClock.now
        let record = try await run("echo $$ > \(shellPID); sleep 31 & echo $! > \(childPID); wait", timeout: .seconds(1))
        #expect(record.timedOut)
        #expect(record.exitCode == nil)
        #expect(ContinuousClock.now - started < .seconds(8))
        for file in [shellPID, childPID] {
            let text = try String(contentsOfFile: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            let pid = try #require(pid_t(text))
            #expect(await waitUntilGone(pid))
        }
    }

    @Test func aCommandThatIgnoresTermIsKilledAfterTheGrace() async throws {
        let started = ContinuousClock.now
        let record = try await run("trap '' TERM; while true; do sleep 1; done", timeout: .seconds(1))
        #expect(record.timedOut && record.exitCode == nil)
        #expect(ContinuousClock.now - started < .seconds(8))
    }

    @Test func outputCapturedBeforeTheTimeoutIsKept() async throws {
        let record = try await run("echo before; sleep 31", timeout: .seconds(2))
        #expect(record.timedOut)
        #expect(record.stdout.text.hasSuffix("before\n"))
    }

    @Test func cancellingTheTaskKillsTheCommand() async throws {
        let shell = self.shell
        let task = Task { try await shell.run(command: "sleep 31", workingDirectory: nil, timeout: .seconds(60), captureLimit: DeviceTextLimit.output) }
        try await Task.sleep(for: .milliseconds(500))
        let started = ContinuousClock.now
        task.cancel()
        let record = try await task.value
        #expect(record.timedOut && record.exitCode == nil)
        #expect(ContinuousClock.now - started < .seconds(8))
    }

    @Test func outputPastTheCapIsCountedNotKept() async throws {
        let record = try await run("head -c 100000 /dev/zero | tr '\\0' 'a'", limit: 1000)
        #expect(record.exitCode == 0)
        #expect(record.stdout.text.utf8.count <= 1000)
        #expect(record.stdout.text.utf8.count + record.stdout.omittedBytes >= 100_000)
        #expect(record.stdout.omittedBytes > 0)
    }

    @Test func fullPipesOnBothStreamsDoNotDeadlock() async throws {
        let record = try await run("head -c 300000 /dev/zero | tr '\\0' 'a'; head -c 300000 /dev/zero | tr '\\0' 'b' >&2; echo end", timeout: .seconds(20))
        #expect(record.exitCode == 0 && !record.timedOut)
        #expect(record.stdout.omittedBytes > 0 && record.stderr.omittedBytes > 0)
    }

    @Test func aBackgroundJobHoldingThePipesDoesNotHangAfterTheShellExits() async throws {
        let started = ContinuousClock.now
        let record = try await run("echo started; (sleep 20 &) ; exit 0", timeout: .seconds(15))
        #expect(record.exitCode == 0 && !record.timedOut)
        #expect(ContinuousClock.now - started < .seconds(8))
    }

    @Test func overTheExecutorTheMarkerEndsAnOversizedStream() async throws {
        let api = FakeConnectorsAPI([.shell: .allowed])
        let ledger = ConnectorLedger(api: api)
        _ = try? await ledger.refresh()
        let executor = DeviceToolExecutor(
            providers: DeviceProviders(shell: shell), permissions: FakePermissions(), ledger: ledger, consent: FakeConsent(true)
        )
        let outcome = await executor.execute(call("shell.run", args: ["command": "head -c 100000 /dev/zero | tr '\\0' 'a'"], deadline: 60))
        let value = try #require(succeeded(outcome))
        let stdout = try #require(value["stdout"]?.stringValue)
        #expect(value["truncated"]?.boolValue == true)
        #expect(stdout.range(of: #"\n…\[truncated \d+ bytes omitted\]$"#, options: .regularExpression) != nil)
        #expect(stdout.utf8.count < 100_000)
        #expect(value["exit_code"]?.intValue == 0)
    }
}

@Suite("Real files provider", .serialized)
struct SystemFilesTests {
    private let files = SystemFiles()

    private func scratch() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func writeThenReadRoundTrips() async throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("note.txt").path
        let written = try await files.write(path: path, content: "héllo\nworld\n", append: false, createDirs: false)
        #expect(written.bytesWritten == 13)
        let read = try await files.read(path: path, captureLimit: DeviceTextLimit.fileContent)
        #expect(read.content == CapturedText(text: "héllo\nworld\n"))
        #expect(read.sizeBytes == 13)
        #expect(read.path == (try DevicePath.resolve(path)))
    }

    @Test func writingReplacesAndAppendingExtends() async throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("log.txt").path
        _ = try await files.write(path: path, content: "one\n", append: false, createDirs: false)
        _ = try await files.write(path: path, content: "two\n", append: true, createDirs: false)
        #expect(try await files.read(path: path, captureLimit: 1000).content.text == "one\ntwo\n")
        _ = try await files.write(path: path, content: "three\n", append: false, createDirs: false)
        #expect(try await files.read(path: path, captureLimit: 1000).content.text == "three\n")
    }

    @Test func replacingAFileKeepsItsPermissions() async throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("run.sh").path
        _ = try await files.write(path: path, content: "#!/bin/sh\n", append: false, createDirs: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        _ = try await files.write(path: path, content: "#!/bin/sh\necho\n", append: false, createDirs: false)
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        #expect(mode == 0o755)
    }

    @Test func aMissingParentIsNotFoundUnlessCreateDirsIsSet() async throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("a/b/c.txt").path
        await #expect(throws: DeviceProviderError.notFound) { try await files.write(path: path, content: "x", append: false, createDirs: false) }
        let written = try await files.write(path: path, content: "x", append: false, createDirs: true)
        #expect(written.bytesWritten == 1)
        #expect(try await files.read(path: path, captureLimit: 10).content.text == "x")
    }

    @Test func aMissingFileIsNotFound() async {
        await #expect(throws: DeviceProviderError.notFound) { try await files.read(path: "/no/such/file-\(UUID().uuidString)", captureLimit: 10) }
        await #expect(throws: DeviceProviderError.notFound) { try await files.list(path: "/no/such/folder-\(UUID().uuidString)", limit: 10) }
    }

    @Test(arguments: ["notes.txt", "./notes.txt", "", "~other/notes.txt"])
    func relativePathsAreInvalid(path: String) async {
        await #expect(throws: DeviceProviderError.self) { try await files.read(path: path, captureLimit: 10) }
        await #expect(throws: DeviceProviderError.self) { try await files.list(path: path, limit: 10) }
        await #expect(throws: DeviceProviderError.self) { try await files.write(path: path, content: "x", append: false, createDirs: false) }
    }

    @Test func readingAFolderAndListingAFileAreInvalid() async throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("f.txt").path
        _ = try await files.write(path: file, content: "x", append: false, createDirs: false)
        await #expect(throws: DeviceProviderError.self) { try await files.read(path: directory.path, captureLimit: 10) }
        await #expect(throws: DeviceProviderError.self) { try await files.list(path: file, limit: 10) }
        await #expect(throws: DeviceProviderError.self) { try await files.write(path: directory.path, content: "x", append: false, createDirs: false) }
    }

    @Test func listingReportsKindsSizesAndTimesSortedByName() async throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await files.write(path: directory.appendingPathComponent("b.txt").path, content: "12345", append: false, createDirs: false)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("a-folder"), withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(atPath: directory.appendingPathComponent("c-link").path, withDestinationPath: "b.txt")
        let listing = try await files.list(path: directory.path, limit: 10)
        #expect(listing.entries.map(\.name) == ["a-folder", "b.txt", "c-link"])
        #expect(listing.entries.map(\.kind) == [.directory, .file, .symlink])
        #expect(listing.entries[1].sizeBytes == 5)
        #expect(listing.entries[0].sizeBytes == nil)
        #expect(listing.entries.allSatisfy { $0.modified != nil })
        #expect(!listing.truncated)
    }

    @Test func aListingPastTheLimitIsTruncated() async throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        for index in 0..<5 {
            _ = try await files.write(path: directory.appendingPathComponent("f\(index).txt").path, content: "", append: false, createDirs: false)
        }
        let listing = try await files.list(path: directory.path, limit: 2)
        #expect(listing.entries.map(\.name) == ["f0.txt", "f1.txt"])
        #expect(listing.truncated)
    }

    @Test func aBigFileIsCappedAtAWholeCharacterAndReportsItsSize() async throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("big.txt").path
        _ = try await files.write(path: path, content: String(repeating: "€", count: 5000), append: false, createDirs: false)
        let read = try await files.read(path: path, captureLimit: 1000)
        #expect(read.sizeBytes == 15_000)
        #expect(read.content.text.utf8.count == 999)
        #expect(read.content.omittedBytes == 15_000 - 999)
        #expect(!read.content.text.contains("\u{FFFD}"))
    }

    @Test(.enabled(if: geteuid() != 0, "root ignores file modes"))
    func anUnreadableFileIsPermissionDeniedAndNamesThePath() async throws {
        let directory = try scratch()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let path = directory.appendingPathComponent("secret.txt").path
        _ = try await files.write(path: path, content: "x", append: false, createDirs: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)
        let resolved = try DevicePath.resolve(path)
        await #expect(throws: DeviceProviderError.accessDenied(resolved)) { try await files.read(path: path, captureLimit: 10) }
        await #expect(throws: DeviceProviderError.accessDenied(resolved)) { try await files.write(path: path, content: "y", append: false, createDirs: false) }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: directory.path)
        await #expect(throws: DeviceProviderError.accessDenied(try DevicePath.resolve(directory.path))) { try await files.list(path: directory.path, limit: 10) }
    }

    @Test func overTheExecutorAPermissionRefusalCarriesThePath() async throws {
        guard geteuid() != 0 else { return }
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("secret.txt").path
        _ = try await files.write(path: path, content: "x", append: false, createDirs: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)
        let ledger = ConnectorLedger(api: FakeConnectorsAPI([.files: .allowed]))
        _ = try? await ledger.refresh()
        let executor = DeviceToolExecutor(providers: DeviceProviders(files: files), permissions: FakePermissions(), ledger: ledger, consent: FakeConsent(true))
        let refusal = failed(await executor.execute(call("files.read", args: ["path": .string(path)])))
        let resolved = try DevicePath.resolve(path)
        #expect(refusal?.0 == .permissionDenied)
        #expect(refusal?.1.contains(resolved) == true)
    }
}
#endif
