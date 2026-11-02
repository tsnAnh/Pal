import Foundation
import HermesAuth
import HermesChat
import HermesClient
import HermesDiagnostics
import HermesProtocol
import HermesREST
import HermesTransport
import SQLite3
import Synchronization

struct E2EEnvironment {
    let home: URL
    let profiles: [String]
    let stubLog: URL
    let gatewayLog: URL
    let fixtureDirectory: URL?

    static func fromEnvironment() -> E2EEnvironment? {
        let env = ProcessInfo.processInfo.environment
        guard LiveGateway.isConfigured, let home = env["HERMES_IOS_E2E_HOME"], let profiles = env["HERMES_IOS_E2E_PROFILES"],
              let stub = env["HERMES_IOS_E2E_STUB_LOG"], let log = env["HERMES_IOS_E2E_GATEWAY_LOG"]
        else { return nil }
        return E2EEnvironment(
            home: URL(fileURLWithPath: home),
            profiles: profiles.split(separator: ",").map(String.init),
            stubLog: URL(fileURLWithPath: stub),
            gatewayLog: URL(fileURLWithPath: log),
            fixtureDirectory: env["HERMES_IOS_FIXTURE_DIR"].map { URL(fileURLWithPath: $0) }
        )
    }

    static var isConfigured: Bool { fromEnvironment() != nil }

    var concurrencyProfile: String { profiles[0] }
    var conversationProfile: String { profiles[1] }

    func database(_ profile: String) -> StateDB {
        StateDB(path: home.appendingPathComponent("profiles/\(profile)/state.db").path)
    }

    func profileLog(_ profile: String) -> String {
        let url = home.appendingPathComponent("profiles/\(profile)/logs/gateway.log")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    func stubRequests() -> [JSONValue] {
        guard let text = try? String(contentsOf: stubLog, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
    }
}

struct StoredMessage: Equatable {
    var role: String
    var content: String
}

struct StateDB {
    let path: String

    private func rows<T>(_ sql: String, _ bind: [String] = [], _ read: (OpaquePointer) -> T) -> [T] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { return [] }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 5000)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        for (index, value) in bind.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        var out: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW { out.append(read(statement)) }
        return out
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }

    func sessionIDs(titled title: String) -> [String] {
        rows("select id from sessions where title = ?1", [title]) { Self.text($0, 0) }
    }

    func sessionCount() -> Int {
        rows("select count(*) from sessions") { Int(sqlite3_column_int($0, 0)) }.first ?? 0
    }

    func conversation(sessionID: String) -> [StoredMessage] {
        rows(
            "select role, coalesce(content, '') from messages where session_id = ?1 and active = 1 and role in ('user', 'assistant') and coalesce(display_kind, '') <> 'hidden' and coalesce(content, '') <> '' order by id",
            [sessionID]
        ) { StoredMessage(role: Self.text($0, 0), content: Self.text($0, 1)) }
    }

    func admissionCount(requestID: String) -> Int {
        rows("select count(*) from session_admissions where request_id = ?1", [requestID]) { Int(sqlite3_column_int($0, 0)) }.first ?? 0
    }

    func admissionIDs(requestID: String) -> [String] {
        rows("select admission_id from session_admissions where request_id = ?1", [requestID]) { Self.text($0, 0) }
    }
}

final class FrameRecorder: Sendable {
    struct Line: Sendable {
        var client: String
        var connection: Int
        var direction: FrameDirection
        var frame: String
    }

    private let lines = Mutex<[Line]>([])
    private let environment: E2EEnvironment

    init(environment: E2EEnvironment) {
        self.environment = environment
    }

    func tap(client: String, connection: Int) -> FrameTap {
        { [self] direction, frame in
            lines.withLock { $0.append(Line(client: client, connection: connection, direction: direction, frame: frame)) }
        }
    }

    func write(name: String, expected: [String: Transcript.Summary]) throws {
        guard let directory = environment.fixtureDirectory else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var output: [String] = []
        for line in lines.withLock({ $0 }) {
            guard let parsed = try? JSONDecoder().decode(JSONValue.self, from: Data(line.frame.utf8)) else { continue }
            let record: JSONValue = [
                "kind": "frame",
                "client": .string(line.client),
                "conn": .int(line.connection),
                "dir": .string(line.direction == .inbound ? "in" : "out"),
                "frame": redact(parsed),
            ]
            output.append(Self.encode(record))
        }
        for (client, summary) in expected.sorted(by: { $0.key < $1.key }) {
            let value = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(summary))
            output.append(Self.encode(["kind": "expected", "client": .string(client), "summary": value]))
        }
        try (output.joined(separator: "\n") + "\n").write(
            to: directory.appendingPathComponent("\(name).jsonl"), atomically: true, encoding: .utf8
        )
    }

    private func redact(_ value: JSONValue, key: String? = nil) -> JSONValue {
        switch value {
        case .string(let text):
            if key == "system_prompt" { return .string("<redacted:system_prompt>") }
            return .string(redact(text))
        case .array(let items):
            return .array(items.map { redact($0) })
        case .object(let object):
            return .object(object.reduce(into: [:]) { $0[$1.key] = redact($1.value, key: $1.key) })
        default:
            return value
        }
    }

    private func redact(_ text: String) -> String {
        var result = text
        let env = ProcessInfo.processInfo.environment
        if let password = env["HERMES_IOS_TEST_PASSWORD"], !password.isEmpty {
            result = result.replacingOccurrences(of: password, with: "<redacted>")
        }
        result = result.replacingOccurrences(of: "/private" + environment.home.path, with: "<HERMES_HOME>")
        result = result.replacingOccurrences(of: environment.home.path, with: "<HERMES_HOME>")
        result = result.replacingOccurrences(of: NSHomeDirectory(), with: "<USER_HOME>")
        result = result.replacingOccurrences(
            of: #"(/private)?/tmp/hermes-ios-e2e\.[A-Za-z0-9]+"#, with: "<E2E_WORKDIR>", options: .regularExpression
        )
        result = result.replacingOccurrences(of: #"127\.0\.0\.1:\d+"#, with: "127.0.0.1:<PORT>", options: .regularExpression)
        result = result.replacingOccurrences(
            of: #"(Bearer |ticket[=.])[A-Za-z0-9._\-]{16,}"#, with: "$1<redacted>", options: .regularExpression
        )
        return result
    }

    private static func encode(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: (try? encoder.encode(value)) ?? Data(), as: UTF8.self)
    }
}

final class TestConnector: ChatConnector {
    private let auth: AuthSession
    private let transport: any HTTPTransport
    private let diagnostics: Diagnostics
    private let recorder: FrameRecorder?
    private let label: String
    private let offline = Mutex(false)
    private let dials = Mutex<[GatewayConnection]>([])

    init(auth: AuthSession, transport: any HTTPTransport, diagnostics: Diagnostics, recorder: FrameRecorder?, label: String) {
        self.auth = auth
        self.transport = transport
        self.diagnostics = diagnostics
        self.recorder = recorder
        self.label = label
    }

    var isOffline: Bool {
        get { offline.withLock { $0 } }
        set { offline.withLock { $0 = newValue } }
    }

    var connections: [GatewayConnection] { dials.withLock { $0 } }
    var latestConnection: GatewayConnection? { connections.last }

    func connect() async throws -> GatewayConnection {
        if isOffline { throw GatewayTransportError.closed(.lost) }
        let index = dials.withLock { $0.count }
        let options = GatewayDialOptions(frameTap: recorder?.tap(client: label, connection: index))
        let client = HermesClient(auth: auth, transport: transport, diagnostics: diagnostics, dialOptions: options)
        let connection = try await client.connect()
        dials.withLock { $0.append(connection) }
        return connection
    }
}

enum E2ETimeout: Error, CustomStringConvertible {
    case waiting(String)

    var description: String {
        switch self {
        case .waiting(let what): "timed out waiting for \(what)"
        }
    }
}

func waitUntil(
    _ what: String,
    timeout: Duration = .seconds(90),
    _ condition: @Sendable () async -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(50))
    }
    throw E2ETimeout.waiting(what)
}

func nonce(_ label: String) -> String {
    "\(label)-\(UUID().uuidString.prefix(8))"
}
