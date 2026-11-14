import Foundation
import Observation
import PalProtocol
import PalTransport

public enum KitOperation: String, Sendable, Equatable {
    case update
    case reload
    case rotate
}

public enum KitReloadTarget: String, Sendable, Equatable {
    case routes
    case gateway
}

public struct KitCredential: Sendable, Equatable {
    public let present: Bool?
    public let created: Bool?
    public let rotated: Bool?
    public let createdAt: String?

    init?(_ value: JSONValue?) {
        guard let value, value.objectValue != nil else { return nil }
        present = value["present"]?.boolValue
        created = value["created"]?.boolValue
        rotated = value["rotated"]?.boolValue
        createdAt = value["created_at"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        if present == nil, created == nil, rotated == nil, createdAt == nil { return nil }
    }

    public var summary: String? {
        let when = createdAt.map { " at \($0)" } ?? ""
        if rotated == true { return "Key replaced" + when }
        if created == true { return "Credential created" + when }
        if present == true { return "Credential present" + (createdAt.map { ", created at \($0)" } ?? "") }
        if present == false { return "No credential yet" }
        return nil
    }
}

public struct KitReport: Sendable, Equatable {
    public let version: String?
    public let status: String?
    public let message: String?
    public let nextAction: String?
    public let credential: KitCredential?

    init(_ value: JSONValue?) {
        version = Self.text(value?["version"]?.stringValue)
        status = Self.text(value?["status"]?.stringValue)
        message = Self.text(value?["message"]?.stringValue)
        nextAction = Self.text(value?["next_action"]?.stringValue)
        credential = KitCredential(value?["credential"])
    }

    private static func text(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

public enum KitFailure: Error, Sendable, Equatable {
    case gatewayUnsupported
    case kitUnavailable
    case kitUnsupported(subcommand: String?)
    case timeout
    case busy
    case credentialMissing
    case credentialUnreadable
    case failed(tail: String?)
    case invalidOutput(tail: String?)
    case requestRefused
    case unreachable

    static func classify(_ error: any Error) -> KitFailure {
        if let failure = error as? KitFailure { return failure }
        guard case GatewayTransportError.rpc(let rpc) = error else { return .unreachable }
        switch rpc.code {
        case -32601: return .gatewayUnsupported
        case 4409: return .busy
        default: return from(code: rpc.data?["code"]?.stringValue, data: rpc.data)
        }
    }

    static func from(code: String?, data: JSONValue?) -> KitFailure {
        let tail = data?["tail"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        switch code {
        case "kit_unavailable": return .kitUnavailable
        case "kit_unsupported": return .kitUnsupported(subcommand: data?["subcommand"]?.stringValue)
        case "timeout": return .timeout
        case "busy": return .busy
        case "invalid_output": return .invalidOutput(tail: tail)
        case "request_refused": return .requestRefused
        case "credential_missing": return .credentialMissing
        case "credential_unreadable": return .credentialUnreadable
        default: return .failed(tail: tail)
        }
    }

    public var message: String {
        switch self {
        case .gatewayUnsupported: "This gateway does not support the kit yet."
        case .kitUnavailable: "The kit isn't installed on this computer."
        case .kitUnsupported: "This kit version does not support this yet."
        case .timeout: "The kit took too long to answer. Try again."
        case .busy: "The kit is busy with another operation."
        case .credentialMissing: "The app has no key to the kit on this machine yet. The first Update kit creates it."
        case .credentialUnreadable: "The app's key to the kit can't be read on this machine."
        case .failed: "The kit reported a failure."
        case .invalidOutput: "The kit's answer wasn't readable."
        case .requestRefused: "The kit on this machine is not set up for the app yet."
        case .unreachable: "Couldn't reach the kit. Try again."
        }
    }

    public var tail: String? {
        switch self {
        case .failed(let tail), .invalidOutput(let tail): tail
        default: nil
        }
    }
}

public enum KitJobState: Sendable, Equatable {
    case running
    case succeeded(KitReport)
    case failed(KitFailure)
}

public struct KitJob: Sendable, Equatable {
    public let id: String
    public let state: KitJobState

    init?(_ value: JSONValue) {
        guard let id = value["job_id"]?.stringValue, !id.isEmpty else { return nil }
        self.id = id
        switch value["state"]?.stringValue {
        case "running": state = .running
        case "succeeded": state = .succeeded(KitReport(value["report"]))
        case "failed": state = .failed(.from(code: value["error"]?["code"]?.stringValue, data: value["error"]))
        default: return nil
        }
    }
}

public struct KitClient: Sendable {
    private let gateway: BotsGateway

    public init(gateway: BotsGateway) {
        self.gateway = gateway
    }

    public func status() async throws -> KitReport {
        let result = try await perform("host.kit.status")
        guard result.objectValue != nil else { throw KitFailure.unreachable }
        return KitReport(result)
    }

    public func start(_ operation: KitOperation, target: KitReloadTarget? = nil) async throws -> KitJob {
        var params: [String: JSONValue] = [:]
        if let target { params["target"] = .string(target.rawValue) }
        guard let job = KitJob(try await perform("host.kit.\(operation.rawValue)", params)) else { throw KitFailure.unreachable }
        return job
    }

    public func job(_ id: String) async throws -> KitJob {
        guard let job = KitJob(try await perform("host.kit.job", ["job_id": .string(id)])) else { throw KitFailure.unreachable }
        return job
    }

    private func perform(_ method: String, _ params: [String: JSONValue] = [:]) async throws -> JSONValue {
        do {
            return try await gateway.call(method, params)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw KitFailure.classify(error)
        }
    }
}

@MainActor
@Observable
public final class KitModel {
    public enum Phase: Sendable, Equatable {
        case loading
        case ready(KitReport)
        case failed(KitFailure)
    }

    public enum Outcome: Sendable, Equatable {
        case succeeded(KitOperation, KitReport)
        case failed(KitOperation, KitFailure)
    }

    static let pollInterval = Duration.seconds(2)
    static let maxPolls = 480
    static let maxPollFailures = 3

    public private(set) var phase: Phase = .loading
    public private(set) var running: KitOperation?
    public private(set) var outcome: Outcome?
    @ObservationIgnored private let client: KitClient
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let surfaces: SurfaceCache
    private static let surfaceKey = SurfaceKey.screen("host-kit")

    public init(
        client: KitClient, surfaces: SurfaceCache,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.client = client
        self.surfaces = surfaces
        self.sleep = sleep
        if let held = surfaces.remembered(KitReport.self, Self.surfaceKey) { phase = .ready(held) }
    }

    public var report: KitReport? {
        if case .ready(let report) = phase { report } else { nil }
    }

    public var isRefused: Bool {
        if case .failed(.requestRefused) = phase { return true }
        if case .failed(_, .requestRefused)? = outcome { return true }
        return false
    }

    public var canAct: Bool {
        guard running == nil, !isRefused else { return false }
        switch phase {
        case .loading, .failed(.gatewayUnsupported), .failed(.busy): return false
        default: return true
        }
    }

    public var canRotate: Bool {
        canAct && phase != .failed(.credentialMissing)
    }

    public var credentialText: String? {
        if case .succeeded(_, let report)? = outcome, let text = report.credential?.summary { return text }
        if phase == .failed(.credentialMissing) { return "Not created yet" }
        return report?.credential?.summary
    }

    public func refreshStatus() async {
        do {
            let fresh = try await client.status()
            phase = .ready(fresh)
            surfaces.remember(fresh, Self.surfaceKey)
            if case .failed(_, .requestRefused)? = outcome { outcome = nil }
        } catch is CancellationError {
            return
        } catch {
            let failure = KitFailure.classify(error)
            if report != nil, failure == .unreachable || failure == .timeout { return }
            phase = .failed(failure)
        }
    }

    public func update() async { await run(.update) }
    public func rotate() async { await run(.rotate) }
    public func reload(_ target: KitReloadTarget) async { await run(.reload, target: target) }

    private func run(_ operation: KitOperation, target: KitReloadTarget? = nil) async {
        guard running == nil else { return }
        running = operation
        outcome = nil
        defer { running = nil }
        do {
            let started = try await client.start(operation, target: target)
            outcome = try await finish(operation, started)
            await refreshStatus()
        } catch is CancellationError {
            return
        } catch {
            outcome = .failed(operation, KitFailure.classify(error))
        }
    }

    private func finish(_ operation: KitOperation, _ started: KitJob) async throws -> Outcome {
        var job = started
        var failures = 0
        for _ in 0..<Self.maxPolls {
            switch job.state {
            case .succeeded(let report): return .succeeded(operation, report)
            case .failed(let failure): return .failed(operation, failure)
            case .running: break
            }
            try await sleep(Self.pollInterval)
            do {
                job = try await client.job(started.id)
                failures = 0
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures += 1
                if failures >= Self.maxPollFailures { return .failed(operation, .unreachable) }
            }
        }
        return .failed(operation, .timeout)
    }
}
