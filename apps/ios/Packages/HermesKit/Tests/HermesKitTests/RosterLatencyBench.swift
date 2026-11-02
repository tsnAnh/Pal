import Foundation
import HermesAuth
import HermesClient
import HermesDiagnostics
import HermesProtocol
import HermesREST
import HermesRoster
import HermesTransport
import Synchronization
import Testing

private struct BenchSide: Decodable, Sendable {
    var label: String
    var baseURL: String
    var username: String
    var password: String
    var home: String

    enum CodingKeys: String, CodingKey {
        case label, username, password, home
        case baseURL = "base_url"
    }
}

private struct BenchConfig: Sendable {
    var sides: [BenchSide]
    var plan: [PlanItem]
    var outDirectory: URL
    var clientPath: String
    var settle: ClosedRange<Double>
    var idleTimeout: Double
    var seed: UInt64

    struct PlanItem: Sendable {
        var side: String
        var profile: String
        var warmup: Bool
    }

    static func fromEnvironment() -> BenchConfig? {
        let env = ProcessInfo.processInfo.environment
        guard let sidesJSON = env["HERMES_BENCH_SIDES"], let plan = env["HERMES_BENCH_PLAN"], let out = env["HERMES_BENCH_OUT"],
              let client = env["HERMES_BENCH_CLIENT"],
              let sides = try? JSONDecoder().decode([BenchSide].self, from: Data(sidesJSON.utf8))
        else { return nil }
        let items = plan.split(separator: ",").compactMap { entry -> PlanItem? in
            let parts = entry.split(separator: ":").map(String.init)
            guard parts.count == 3 else { return nil }
            return PlanItem(side: parts[0], profile: parts[1], warmup: parts[2] == "warm")
        }
        let low = Double(env["HERMES_BENCH_SETTLE_MIN"] ?? "") ?? 5
        let high = max(low, Double(env["HERMES_BENCH_SETTLE_MAX"] ?? "") ?? 60)
        return BenchConfig(
            sides: sides,
            plan: items,
            outDirectory: URL(fileURLWithPath: out),
            clientPath: client,
            settle: low...high,
            idleTimeout: Double(env["HERMES_BENCH_IDLE_TIMEOUT"] ?? "") ?? 100,
            seed: UInt64(env["HERMES_BENCH_SEED"] ?? "") ?? 1
        )
    }
}

private func wallClock() -> Double { Date().timeIntervalSince1970 }

private struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    mutating func uniform(_ range: ClosedRange<Double>) -> Double {
        range.lowerBound + Double(next() >> 11) / Double(1 << 53) * (range.upperBound - range.lowerBound)
    }
}

private struct ProfileView: Sendable {
    var activity: BotActivity
    var messageCount: Int?
    var lastActive: Double?
}

private struct SnapshotRecord: Sendable {
    var t: Double
    var profiles: [String: ProfileView]
}

private struct EventRecord: Sendable {
    var side: String
    var t: Double
    var kind: String
    var detail: String
}

private final class BenchStore: Sendable {
    private let snapshotLog = Mutex<[String: [SnapshotRecord]]>([:])
    private let eventLog = Mutex<[EventRecord]>([])

    func add(_ snapshot: SnapshotRecord, side: String) {
        snapshotLog.withLock { $0[side, default: []].append(snapshot) }
    }

    func add(_ event: EventRecord) {
        eventLog.withLock { $0.append(event) }
    }

    func snapshots(_ side: String) -> [SnapshotRecord] { snapshotLog.withLock { $0[side] ?? [] } }
    func latest(_ side: String) -> SnapshotRecord? { snapshotLog.withLock { $0[side]?.last } }
    var events: [EventRecord] { eventLog.withLock { $0 } }
    var allSnapshots: [(String, SnapshotRecord)] {
        snapshotLog.withLock { $0.sorted { $0.key < $1.key }.flatMap { side, rows in rows.map { (side, $0) } } }
    }
}

private final class ClientOutput: Sendable {
    struct State {
        var buffer = ""
        var admittedAt: Double?
        var completedAt: Double?
        var sessionID: String?
        var status: String?
    }

    let state = Mutex(State())

    func feed(_ data: Data) {
        guard !data.isEmpty else { return }
        state.withLock { state in
            state.buffer += String(decoding: data, as: UTF8.self)
            while let newline = state.buffer.firstIndex(of: "\n") {
                let line = String(state.buffer[..<newline])
                state.buffer.removeSubrange(...newline)
                guard let frame = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)) else { continue }
                let stamp: Double? = switch frame["t"] {
                case .double(let value)?: value
                case .int(let value)?: Double(value)
                default: nil
                }
                if frame["admitted"]?.boolValue == true {
                    state.admittedAt = stamp
                    state.sessionID = frame["session_id"]?.stringValue
                    state.status = frame["status"]?.stringValue
                }
                if frame["completed"]?.boolValue == true { state.completedAt = stamp }
            }
        }
    }
}

private struct RunRecord: Sendable {
    var index: Int
    var side: String
    var profile: String
    var warmup: Bool
    var settle: Double
    var loadAverages: [Double]
    var baselineCount: Int
    var baselineIdle: Bool
    var spawnedAt: Double
    var admittedAt: Double?
    var workingAt: Double?
    var completedAt: Double?
    var idleNewAt: Double?
    var idleAnyAt: Double?
    var countNewAt: Double?
    var sessionID: String
    var prompt: String
    var errors: [String]
    var dbTurnComplete: Bool
}

private actor SideRuntime {
    let side: BenchSide
    let feed: RosterLiveFeed
    var monitor: Task<Void, Never>?

    init(side: BenchSide, store: BenchStore) async throws {
        self.side = side
        let transport = RecordingTransport()
        let browser = ProgrammaticBrowser(username: side.username, password: side.password)
        let credentials = try await NativeSignIn(transport: transport).signIn(
            baseURL: try GatewayBaseURL(validating: side.baseURL), browser: browser
        )
        let auth = try AuthSession(store: InMemoryCredentialStore(), transport: transport)
        try await auth.adopt(credentials)
        let label = side.label
        let tap: FrameTap = { direction, frame in
            switch direction {
            case .outbound where frame.contains("\"profiles.list\""):
                store.add(EventRecord(side: label, t: wallClock(), kind: "refresh-start", detail: ""))
            case .inbound where frame.contains("\"sessions.changed\""):
                store.add(EventRecord(side: label, t: wallClock(), kind: "event", detail: "sessions.changed"))
            case .inbound where frame.contains("\"platforms.changed\""):
                store.add(EventRecord(side: label, t: wallClock(), kind: "event", detail: "platforms.changed"))
            default:
                break
            }
        }
        let client = HermesClient(auth: auth, transport: transport, dialOptions: GatewayDialOptions(frameTap: tap))
        feed = RosterLiveFeed(connect: {
            store.add(EventRecord(side: label, t: wallClock(), kind: "dial", detail: ""))
            return try await client.connect()
        })
    }

    func start(store: BenchStore) async {
        let label = side.label
        let updates = feed.updates
        monitor = Task {
            for await update in updates {
                switch update {
                case .link(let link):
                    store.add(EventRecord(side: label, t: wallClock(), kind: "link", detail: "\(link)"))
                case .snapshot(let snapshot):
                    store.add(Self.record(snapshot), side: label)
                }
            }
        }
        await feed.start()
    }

    func stop() async {
        await feed.stop()
        monitor?.cancel()
    }

    private static func record(_ snapshot: RosterSnapshot) -> SnapshotRecord {
        var views: [String: ProfileView] = [:]
        for row in snapshot.profiles {
            guard let name = row["name"]?.stringValue else { continue }
            let canonical = row["canonical_session"]
            let lastActive: Double? = switch canonical?["last_active"] {
            case .double(let value)?: value
            case .int(let value)?: Double(value)
            default: nil
            }
            views[name] = ProfileView(
                activity: BotActivity.derive(link: .connected, live: snapshot.live[name], hasLocalPrompt: false, now: snapshot.receivedAt),
                messageCount: canonical?["message_count"]?.intValue,
                lastActive: lastActive
            )
        }
        return SnapshotRecord(t: snapshot.receivedAt.timeIntervalSince1970, profiles: views)
    }
}

private func loadAverages() -> [Double] {
    var loads = [Double](repeating: 0, count: 3)
    _ = getloadavg(&loads, 3)
    return loads
}

private func csv(_ fields: [String]) -> String {
    fields.map { field in
        field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) ? "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : field
    }.joined(separator: ",")
}

private func format(_ value: Double?) -> String {
    value.map { String(format: "%.4f", $0) } ?? ""
}

private func stateDBPath(_ side: BenchSide, profile: String) -> String {
    profile == "default" ? "\(side.home)/state.db" : "\(side.home)/profiles/\(profile)/state.db"
}

private func write(_ config: BenchConfig, runs: [RunRecord], store: BenchStore) throws {
    try FileManager.default.createDirectory(at: config.outDirectory, withIntermediateDirectories: true)
    var runLines = [csv([
        "index", "side", "profile", "warmup", "settle_s", "load1", "load5", "load15", "baseline_count", "baseline_idle",
        "t_spawn", "t_admit", "t_working", "t_complete", "t_idle_new", "t_idle_any", "t_count_new", "session_id", "prompt",
        "db_turn_complete", "errors",
    ])]
    for run in runs {
        runLines.append(csv([
            "\(run.index)", run.side, run.profile, run.warmup ? "1" : "0", format(run.settle),
            format(run.loadAverages[0]), format(run.loadAverages[1]), format(run.loadAverages[2]),
            "\(run.baselineCount)", run.baselineIdle ? "1" : "0", format(run.spawnedAt), format(run.admittedAt),
            format(run.workingAt), format(run.completedAt), format(run.idleNewAt), format(run.idleAnyAt), format(run.countNewAt),
            run.sessionID, run.prompt, run.dbTurnComplete ? "1" : "0", run.errors.joined(separator: ";"),
        ]))
    }
    try (runLines.joined(separator: "\n") + "\n").write(
        to: config.outDirectory.appendingPathComponent("runs.csv"), atomically: true, encoding: .utf8
    )
    var eventLines = [csv(["side", "t", "kind", "detail"])]
    for event in store.events.sorted(by: { $0.t < $1.t }) {
        eventLines.append(csv([event.side, format(event.t), event.kind, event.detail]))
    }
    try (eventLines.joined(separator: "\n") + "\n").write(
        to: config.outDirectory.appendingPathComponent("events.csv"), atomically: true, encoding: .utf8
    )
    var snapshotLines = [csv(["side", "t", "profile", "activity", "message_count", "last_active"])]
    for (side, snapshot) in store.allSnapshots {
        for (name, view) in snapshot.profiles.sorted(by: { $0.key < $1.key }) {
            snapshotLines.append(csv([
                side, format(snapshot.t), name, view.activity.accessibilityValue, view.messageCount.map(String.init) ?? "",
                format(view.lastActive),
            ]))
        }
    }
    try (snapshotLines.joined(separator: "\n") + "\n").write(
        to: config.outDirectory.appendingPathComponent("snapshots.csv"), atomically: true, encoding: .utf8
    )
}

private func execute(
    index: Int,
    item: BenchConfig.PlanItem,
    side: BenchSide,
    config: BenchConfig,
    store: BenchStore,
    random: inout SplitMix64
) async -> RunRecord {
    let settle = random.uniform(config.settle)
    try? await Task.sleep(for: .seconds(settle))

    var errors: [String] = []
    var baselineIdle = false
    let baselineDeadline = ContinuousClock.now + .seconds(90)
    while ContinuousClock.now < baselineDeadline {
        if let latest = store.latest(side.label)?.profiles[item.profile], latest.activity == .idle {
            baselineIdle = true
            break
        }
        try? await Task.sleep(for: .milliseconds(100))
    }
    if !baselineIdle { errors.append("baseline-not-idle") }
    let baselineView = store.latest(side.label)?.profiles[item.profile]
    let baselineCount = baselineView?.messageCount ?? 0

    let prompt = "SLOW bench \(side.label) \(index)"
    let load = loadAverages()
    let output = ClientOutput()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: config.clientPath)
    process.arguments = ["submit", "--profile", item.profile, "--text", prompt, "--hold", "90"]
    var environment = ProcessInfo.processInfo.environment
    environment["HERMES_IOS_TEST_BASE_URL"] = side.baseURL
    environment["HERMES_IOS_TEST_USERNAME"] = side.username
    environment["HERMES_IOS_TEST_PASSWORD"] = side.password
    process.environment = environment
    let pipe = Pipe()
    process.standardOutput = pipe
    let errorURL = config.outDirectory.appendingPathComponent("client-\(index)-\(side.label).err")
    FileManager.default.createFile(atPath: errorURL.path, contents: nil)
    process.standardError = try? FileHandle(forWritingTo: errorURL)
    pipe.fileHandleForReading.readabilityHandler = { handle in output.feed(handle.availableData) }

    let spawnedAt = wallClock()
    do {
        try process.run()
    } catch {
        errors.append("spawn-failed")
        return RunRecord(
            index: index, side: side.label, profile: item.profile, warmup: item.warmup, settle: settle, loadAverages: load,
            baselineCount: baselineCount, baselineIdle: baselineIdle, spawnedAt: spawnedAt, sessionID: "", prompt: prompt,
            errors: errors, dbTurnComplete: false
        )
    }

    let admitDeadline = ContinuousClock.now + .seconds(40)
    while output.state.withLock({ $0.admittedAt }) == nil, process.isRunning, ContinuousClock.now < admitDeadline {
        try? await Task.sleep(for: .milliseconds(20))
    }
    if output.state.withLock({ $0.admittedAt }) == nil { errors.append("submit-failed") }

    let completeDeadline = ContinuousClock.now + .seconds(100)
    while output.state.withLock({ $0.completedAt }) == nil, process.isRunning, ContinuousClock.now < completeDeadline {
        try? await Task.sleep(for: .milliseconds(20))
    }
    let completedAt = output.state.withLock { $0.completedAt }
    if completedAt == nil { errors.append("no-message-complete") }

    let idleDeadline = ContinuousClock.now + .seconds(config.idleTimeout)
    func after(_ predicate: (ProfileView) -> Bool) -> Double? {
        store.snapshots(side.label).first { $0.t > spawnedAt && ($0.profiles[item.profile].map(predicate) ?? false) }?.t
    }
    if completedAt != nil {
        while ContinuousClock.now < idleDeadline {
            if after({ $0.activity == .idle && ($0.messageCount ?? 0) >= baselineCount + 2 }) != nil { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    let admittedAt = output.state.withLock { $0.admittedAt }
    let workingAt = after { $0.activity == .working }
    let idleNewAt = completedAt.flatMap { completed in
        store.snapshots(side.label).first {
            $0.t > spawnedAt && ($0.profiles[item.profile].map { $0.activity == .idle && ($0.messageCount ?? 0) >= baselineCount + 2 } ?? false)
               
        }?.t
    }
    let idleAnyAt = completedAt.flatMap { completed in
        store.snapshots(side.label).first { $0.t >= completed && $0.profiles[item.profile]?.activity == .idle }?.t
    }
    let countNewAt = after { ($0.messageCount ?? 0) >= baselineCount + 2 }
    if workingAt == nil || (completedAt != nil && workingAt! > completedAt!) { errors.append("missed-working-edge") }
    if completedAt != nil && idleNewAt == nil { errors.append("idle-edge-timeout") }

    let sessionID = output.state.withLock { $0.sessionID } ?? ""
    let database = StateDB(path: stateDBPath(side, profile: item.profile))
    let stored = sessionID.isEmpty ? [] : database.conversation(sessionID: sessionID)
    let promptIndices = stored.indices.filter { stored[$0].role == "user" && stored[$0].content == prompt }
    let dbTurnComplete = promptIndices.count == 1
        && stored.indices.contains(promptIndices[0] + 1)
        && stored[promptIndices[0] + 1].role == "assistant"
        && !stored[promptIndices[0] + 1].content.isEmpty
    if !dbTurnComplete { errors.append("db-turn-incomplete") }

    pipe.fileHandleForReading.readabilityHandler = nil
    if process.isRunning {
        let exitDeadline = ContinuousClock.now + .seconds(5)
        while process.isRunning, ContinuousClock.now < exitDeadline { try? await Task.sleep(for: .milliseconds(50)) }
        if process.isRunning { process.terminate() }
    }

    return RunRecord(
        index: index, side: side.label, profile: item.profile, warmup: item.warmup, settle: settle, loadAverages: load,
        baselineCount: baselineCount, baselineIdle: baselineIdle, spawnedAt: spawnedAt, admittedAt: admittedAt,
        workingAt: workingAt, completedAt: completedAt, idleNewAt: idleNewAt, idleAnyAt: idleAnyAt, countNewAt: countNewAt,
        sessionID: sessionID, prompt: prompt, errors: errors, dbTurnComplete: dbTurnComplete
    )
}

@Suite("Roster latency bench", .serialized, .enabled(if: BenchConfig.fromEnvironment() != nil, "set HERMES_BENCH_* to run the roster latency bench"))
struct RosterLatencyBench {
    @Test(.timeLimit(.minutes(120)))
    func externalTurnLatencyThroughRealRosterFeed() async throws {
        let config = try #require(BenchConfig.fromEnvironment())
        let store = BenchStore()
        var runtimes: [String: SideRuntime] = [:]
        for side in config.sides {
            let runtime = try await SideRuntime(side: side, store: store)
            await runtime.start(store: store)
            runtimes[side.label] = runtime
        }
        for side in config.sides {
            try await waitUntil("\(side.label) first snapshot", timeout: .seconds(60)) { store.latest(side.label) != nil }
        }

        var random = SplitMix64(state: config.seed)
        var runs: [RunRecord] = []
        for (offset, item) in config.plan.enumerated() {
            guard let side = config.sides.first(where: { $0.label == item.side }) else { continue }
            let run = await execute(index: offset + 1, item: item, side: side, config: config, store: store, random: &random)
            runs.append(run)
            try write(config, runs: runs, store: store)
        }
        for runtime in runtimes.values { await runtime.stop() }
        try write(config, runs: runs, store: store)
        #expect(!runs.isEmpty, "the plan produced no runs")
    }
}
