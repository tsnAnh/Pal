import Foundation
import PalDevice
import PalDiagnostics
import PalProtocol
import PalTransport
import Synchronization

enum RelayE2E {
    static let environment = ProcessInfo.processInfo.environment

    static var controlDirectory: URL? {
        environment["PAL_T3_RELAY_E2E_CTL"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static var stepsFile: URL? {
        environment["PAL_T3_RELAY_E2E_STEPS"].map { URL(fileURLWithPath: $0) }
    }

    static var macLogFile: URL? {
        environment["PAL_T3_RELAY_E2E_MAC_LOG"].map { URL(fileURLWithPath: $0) }
    }

    static var enabled: Bool {
        RealT3.enabled && E2EEnvironment.isConfigured && controlDirectory != nil && stepsFile != nil
    }
}

struct RelayStepFailed: Error, CustomStringConvertible {
    let name: String
    var description: String { "step failed: \(name)" }
}

struct RelayControlFailed: Error, CustomStringConvertible {
    let action: String
    let detail: String
    var description: String { "control \(action) failed: \(detail)" }
}

final class RelayStepLog: Sendable {
    private let file: URL
    private let sequence = Mutex(0)

    init(file: URL) {
        self.file = file
    }

    func record(_ name: String, pass: Bool, observed: JSONValue) {
        let number = sequence.withLock { value -> Int in
            value += 1
            return value
        }
        let line: JSONValue = [
            "source": "swift", "seq": .int(number), "name": .string(name), "pass": .bool(pass),
            "at": .string(Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true)) + "Z"), "observed": observed,
        ]
        guard var data = try? JSONEncoder().encode(line) else { return }
        data.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: file)
        }
    }
}

final class RelayControl: Sendable {
    private let directory: URL
    private let counter = Mutex(0)

    init(directory: URL) {
        self.directory = directory
    }

    @discardableResult
    func request(_ action: String, timeout: Duration = .seconds(120)) async throws -> JSONValue {
        let number = counter.withLock { value -> Int in
            value += 1
            return value
        }
        let name = String(format: "%03d", number)
        let staging = directory.appending(path: "req-\(name).tmp")
        let request = directory.appending(path: "req-\(name).json")
        let response = directory.appending(path: "res-\(name).json")
        try JSONEncoder().encode(["action": action]).write(to: staging)
        try FileManager.default.moveItem(at: staging, to: request)
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let data = try? Data(contentsOf: response), let value = try? JSONDecoder().decode(JSONValue.self, from: data) {
                guard value["ok"]?.boolValue == true else {
                    throw RelayControlFailed(action: action, detail: value["detail"]?.stringValue ?? "no detail")
                }
                return value
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw RelayControlFailed(action: action, detail: "no answer from the harness")
    }
}

final class RelayMacLog: Sendable {
    private let file: URL?
    private let lock = Mutex(())

    init(file: URL?) {
        self.file = file
    }

    func write(_ line: String) {
        guard let file else { return }
        let stamped = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true)) + "Z " + line + "\n"
        lock.withLock { _ in
            if let handle = try? FileHandle(forWritingTo: file) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(stamped.utf8))
            } else {
                try? Data(stamped.utf8).write(to: file)
            }
        }
    }

    var diagnostics: Diagnostics {
        Diagnostics { [self] event in write("\(event.category): \(event.message)") }
    }
}

final class RelayFrameLog: Sendable {
    struct Entry: Sendable {
        var profile: String
        var direction: FrameDirection
        var frame: JSONValue
    }

    private let entries = Mutex<[Entry]>([])
    private let macLog: RelayMacLog

    init(macLog: RelayMacLog) {
        self.macLog = macLog
    }

    func tap(profile: String) -> FrameTap {
        { [self] direction, text in
            guard let frame = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) else { return }
            entries.withLock { $0.append(Entry(profile: profile, direction: direction, frame: frame)) }
            summarize(profile: profile, direction: direction, frame: frame)
        }
    }

    private func summarize(profile: String, direction: FrameDirection, frame: JSONValue) {
        let method = frame["method"]?.stringValue
        let kind = frame["params"]?["type"]?.stringValue
        if let method, method.hasPrefix("device.mcp.") || method == "client.hello" {
            macLog.write("wire \(profile) \(direction.rawValue) \(method) \(frame["params"]?["relay_id"]?.stringValue ?? frame["params"]?["server"]?.stringValue ?? "")")
        } else if let kind, kind.hasPrefix("device.mcp.") {
            macLog.write("wire \(profile) \(direction.rawValue) event \(kind) \(frame["params"]?["payload"]?["relay_id"]?.stringValue ?? "")")
        }
    }

    func outboundCalls(_ method: String, profile: String? = nil) -> [JSONValue] {
        entries.withLock { $0 }
            .filter { $0.direction == .outbound && $0.frame["method"]?.stringValue == method && (profile == nil || $0.profile == profile) }
            .map(\.frame)
    }

    func inboundEvents(_ type: String, profile: String? = nil) -> [JSONValue] {
        entries.withLock { $0 }
            .filter { $0.direction == .inbound && $0.frame["params"]?["type"]?.stringValue == type && (profile == nil || $0.profile == profile) }
            .compactMap { $0.frame["params"]?["payload"] }
    }
}

@MainActor
func pollUntil(_ timeout: Duration, interval: Duration = .milliseconds(250), _ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: interval)
    }
    return await condition()
}

func clipped(_ text: String, _ limit: Int = 400) -> String {
    text.count <= limit ? text : String(text.prefix(limit)) + "..."
}

final class RelayPairingCode: Sendable {
    private let code: Mutex<String>

    init(_ initial: String) {
        code = Mutex(initial)
    }

    var current: String { code.withLock { $0 } }
    func replace(_ value: String) { code.withLock { $0 = value } }
}
