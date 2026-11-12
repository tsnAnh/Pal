import Foundation
import Observation
import PalProtocol
import PalTransport

public enum KitOperation: String, Sendable, Equatable {
    case refresh
    case update
    case addProject = "add_project"
    case reload
}

public enum KitReloadTarget: String, Sendable, Equatable {
    case routes
    case gateway
}

public enum KitRepo {
    public static func isValid(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, !value.contains("..") else { return false }
        let owner = parts[0], name = parts[1]
        guard (1...39).contains(owner.count), (1...100).contains(name.count),
              owner.first.map(isAlphanumeric) == true,
              owner.allSatisfy({ isAlphanumeric($0) || $0 == "-" }),
              name.allSatisfy({ isAlphanumeric($0) || $0 == "." || $0 == "-" || $0 == "_" })
        else { return false }
        return true
    }

    private static func isAlphanumeric(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber)
    }
}

public struct KitReport: Sendable, Equatable {
    public let version: String?
    public let status: String?
    public let message: String?

    init(_ value: JSONValue?) {
        version = Self.text(value?["version"]?.stringValue)
        status = Self.text(value?["status"]?.stringValue)
        message = Self.text(value?["message"]?.stringValue)
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
    case invalidRepo
    case failed(tail: String?)
    case invalidOutput(tail: String?)
    case unreachable

    static func classify(_ error: any Error) -> KitFailure {
        if let failure = error as? KitFailure { return failure }
        guard case GatewayTransportError.rpc(let rpc) = error else { return .unreachable }
        switch rpc.code {
        case -32601: return .gatewayUnsupported
        case 4409: return .busy
        case 4101: return .invalidRepo
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
        case .invalidRepo: "Enter the project as owner/repo."
        case .failed: "The kit reported a failure."
        case .invalidOutput: "The kit's answer wasn't readable."
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

    public func start(_ operation: KitOperation, repo: String? = nil, target: KitReloadTarget? = nil) async throws -> KitJob {
        var params: [String: JSONValue] = [:]
        if let repo { params["repo"] = .string(repo) }
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

    public init(client: KitClient, sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.client = client
        self.sleep = sleep
    }

    public var report: KitReport? {
        if case .ready(let report) = phase { report } else { nil }
    }

    public var canAct: Bool {
        guard running == nil else { return false }
        switch phase {
        case .loading, .failed(.gatewayUnsupported): return false
        default: return true
        }
    }

    public func refreshStatus() async {
        do {
            phase = .ready(try await client.status())
        } catch is CancellationError {
            return
        } catch {
            phase = .failed(KitFailure.classify(error))
        }
    }

    public func refresh() async { await run(.refresh) }
    public func update() async { await run(.update) }
    public func reload(_ target: KitReloadTarget) async { await run(.reload, target: target) }

    public func addProject(_ repo: String) async {
        let trimmed = repo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard KitRepo.isValid(trimmed) else {
            outcome = .failed(.addProject, .invalidRepo)
            return
        }
        await run(.addProject, repo: trimmed)
    }

    private func run(_ operation: KitOperation, repo: String? = nil, target: KitReloadTarget? = nil) async {
        guard running == nil else { return }
        running = operation
        outcome = nil
        defer { running = nil }
        do {
            let started = try await client.start(operation, repo: repo, target: target)
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
