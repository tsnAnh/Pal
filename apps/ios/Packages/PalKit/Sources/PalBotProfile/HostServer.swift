import Foundation
import Observation
import PalProtocol
import PalTransport

public struct HostProblem: Sendable, Equatable {
    public enum Severity: Sendable, Equatable {
        case warning
        case error
    }

    public let severity: Severity
    public let message: String
}

public struct HostHealth: Sendable, Equatable {
    public let version: String?
    public let commit: String?
    public let pythonVersion: String?
    public let platform: String?
    public let diskFreeBytes: Int64?
    public let diskTotalBytes: Int64?
    public let hostUptimeSeconds: Int64?
    public let profileCount: Int?
    public let runningGatewayCount: Int?
    public let doctorRan: Bool
    public let problems: [HostProblem]

    init(_ value: JSONValue) {
        version = Self.text(value["version"])
        commit = Self.text(value["commit"])
        pythonVersion = Self.text(value["python_version"])
        platform = Self.text(value["platform"])
        diskFreeBytes = value["disk_free_bytes"]?.intValue.map(Int64.init)
        diskTotalBytes = value["disk_total_bytes"]?.intValue.map(Int64.init)
        hostUptimeSeconds = value["host_uptime_seconds"]?.intValue.map(Int64.init)
        profileCount = value["profile_count"]?.intValue
        runningGatewayCount = value["running_gateway_count"]?.intValue
        doctorRan = value["doctor_ran"]?.boolValue ?? false
        problems = (value["problems"]?.arrayValue ?? []).compactMap { row in
            guard let message = Self.text(row["message"]) else { return nil }
            return HostProblem(severity: row["severity"]?.stringValue == "error" ? .error : .warning, message: message)
        }
    }

    private static func text(_ value: JSONValue?) -> String? {
        guard let trimmed = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

public enum HostLogName: String, Sendable, CaseIterable, Identifiable {
    case gateway
    case agent
    case errors

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .gateway: "Gateway"
        case .agent: "Agent"
        case .errors: "Errors"
        }
    }
}

public struct HostLogPage: Sendable, Equatable {
    public let lines: [String]
    public let hasMore: Bool
    public let truncated: Bool
    public let available: Bool

    init(_ value: JSONValue) {
        lines = (value["lines"]?.arrayValue ?? []).compactMap(\.stringValue)
        hasMore = value["has_more"]?.boolValue ?? false
        truncated = value["truncated"]?.boolValue ?? false
        available = value["available"]?.boolValue ?? true
    }
}

public enum HostFailure: Error, Sendable, Equatable {
    case unsupported
    case unavailable

    static func classify(_ error: any Error) -> HostFailure {
        if let failure = error as? HostFailure { return failure }
        if case GatewayTransportError.rpc(let rpc) = error, rpc.code == -32601 { return .unsupported }
        return .unavailable
    }
}

public struct HostServerClient: Sendable {
    private let gateway: BotsGateway

    public init(gateway: BotsGateway) {
        self.gateway = gateway
    }

    public func health() async throws -> HostHealth {
        let result = try await perform("host.health", [:])
        guard result.objectValue != nil else { throw HostFailure.unavailable }
        return HostHealth(result)
    }

    public func logs(_ name: HostLogName, lines: Int, skip: Int) async throws -> HostLogPage {
        let result = try await perform(
            "host.logs.tail", ["name": .string(name.rawValue), "lines": .int(lines), "skip": .int(skip)])
        guard result.objectValue != nil else { throw HostFailure.unavailable }
        return HostLogPage(result)
    }

    private func perform(_ method: String, _ params: [String: JSONValue]) async throws -> JSONValue {
        do {
            return try await gateway.call(method, params)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw HostFailure.classify(error)
        }
    }
}

public enum HostLoad<Value: Sendable & Equatable>: Sendable, Equatable {
    case loading
    case loaded(Value)
    case unsupported
    case failed

    public var value: Value? {
        if case .loaded(let value) = self { value } else { nil }
    }
}

@MainActor
@Observable
public final class HostServerModel {
    public static let pageSize = 200

    public private(set) var health: HostLoad<HostHealth> = .loading
    public private(set) var logName: HostLogName = .gateway
    public private(set) var logLines: [String] = []
    public private(set) var logState: HostLoad<HostLogPage> = .loading
    public private(set) var hasOlderLines = false
    public private(set) var isLoadingOlder = false
    @ObservationIgnored private let client: HostServerClient
    @ObservationIgnored private var generation = 0

    public init(client: HostServerClient) {
        self.client = client
    }

    public var logText: String { logLines.joined(separator: "\n") }

    public func refresh() async {
        async let healthLoad: Void = loadHealth()
        async let logsLoad: Void = loadLogs()
        _ = await (healthLoad, logsLoad)
    }

    public func loadHealth() async {
        do {
            health = .loaded(try await client.health())
        } catch is CancellationError {
        } catch HostFailure.unsupported {
            health = .unsupported
        } catch {
            if health.value == nil { health = .failed }
        }
    }

    public func selectLog(_ name: HostLogName) async {
        guard name != logName else { return }
        logName = name
        logLines = []
        logState = .loading
        hasOlderLines = false
        await loadLogs()
    }

    public func loadLogs() async {
        generation += 1
        let mine = generation
        let name = logName
        do {
            let page = try await client.logs(name, lines: Self.pageSize, skip: 0)
            guard mine == generation else { return }
            logLines = page.lines
            hasOlderLines = page.hasMore
            logState = .loaded(page)
        } catch is CancellationError {
        } catch HostFailure.unsupported {
            guard mine == generation else { return }
            logState = .unsupported
        } catch {
            guard mine == generation else { return }
            if logState.value == nil { logState = .failed }
        }
    }

    public func loadOlder() async {
        guard hasOlderLines, !isLoadingOlder, logState.value != nil else { return }
        isLoadingOlder = true
        defer { isLoadingOlder = false }
        let mine = generation
        let name = logName
        do {
            let page = try await client.logs(name, lines: Self.pageSize, skip: logLines.count)
            guard mine == generation, name == logName else { return }
            logLines = page.lines + logLines
            hasOlderLines = page.hasMore
        } catch {
            if mine == generation { hasOlderLines = false }
        }
    }
}
