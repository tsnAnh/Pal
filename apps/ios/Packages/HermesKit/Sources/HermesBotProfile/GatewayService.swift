import Foundation
import HermesProtocol
import HermesTransport

public enum GatewayServiceState: Sendable, Equatable {
    case running
    case stopped
    case notInstalled
    case restartNeeded
    case unsupported
    case unknown

    init(wire: String) {
        switch wire {
        case "running": self = .running
        case "stopped": self = .stopped
        case "not_installed": self = .notInstalled
        case "restart_needed": self = .restartNeeded
        case "unsupported": self = .unsupported
        default: self = .unknown
        }
    }
}

public struct GatewayServiceInfo: Sendable, Equatable {
    public let state: GatewayServiceState
    public let activeRuns: Int
    public let instance: String?
    public let startedAt: Date?
    public let reason: String?

    public var isRunning: Bool { state == .running || state == .restartNeeded }
    public var canRestart: Bool { isRunning || state == .stopped }
    public var canInstall: Bool { state == .notInstalled }
}

public enum GatewayServiceOutcome: Sendable, Equatable {
    case done(GatewayServiceInfo)
    case pending(GatewayServiceInfo?)
    case busy(String)
    case refused(String)
    case unsupported(String)
    case failed(String)
}

struct GatewayServiceStatusWire: Decodable {
    let state: String
    let activeRuns: Int
    let instance: String?
    let startedAt: Double?
    let reason: String?

    enum CodingKeys: String, CodingKey {
        case state, instance, reason
        case activeRuns = "active_runs"
        case startedAt = "started_at"
    }

    var info: GatewayServiceInfo {
        GatewayServiceInfo(
            state: GatewayServiceState(wire: state), activeRuns: activeRuns, instance: instance,
            startedAt: startedAt.map(Date.init(timeIntervalSince1970:)), reason: reason)
    }
}

struct GatewayServiceActionWire: Decodable {
    let outcome: String
    let reason: String?
    let status: GatewayServiceStatusWire
}

public struct GatewayServiceClient: Sendable {
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    public static let defaultPollInterval: Duration = .seconds(2)
    public static let defaultPollLimit = 30

    private let gateway: BotsGateway
    private let sleep: Sleep
    private let pollInterval: Duration
    private let pollLimit: Int

    public init(
        gateway: BotsGateway,
        pollInterval: Duration = GatewayServiceClient.defaultPollInterval,
        pollLimit: Int = GatewayServiceClient.defaultPollLimit,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
        self.gateway = gateway
        self.pollInterval = pollInterval
        self.pollLimit = pollLimit
        self.sleep = sleep
    }

    public func status() async throws -> GatewayServiceInfo {
        do {
            let result = try await gateway.call("gateway.service.status")
            return try gateway.decoded(GatewayServiceStatusWire.self, result).info
        } catch {
            throw BotsError.surface(error)
        }
    }

    public func restart(force: Bool = false) async -> GatewayServiceOutcome {
        let before = try? await status()
        let action: GatewayServiceActionWire
        do {
            action = try await perform("gateway.service.restart", force ? ["force": .bool(true)] : [:])
        } catch is CancellationError {
            return .pending(nil)
        } catch GatewayTransportError.rpc {
            return .failed(Self.couldNotRestart)
        } catch {
            return await awaitNewInstance(replacing: before?.instance)
        }
        switch action.outcome {
        case "started": return await awaitNewInstance(replacing: action.status.instance)
        case "busy": return .busy(action.reason ?? Self.couldNotRestart)
        case "refused": return .refused(action.reason ?? Self.couldNotRestart)
        case "unsupported", "not_installed": return .unsupported(action.reason ?? Self.couldNotRestart)
        default: return .failed(action.reason ?? Self.couldNotRestart)
        }
    }

    public func install() async -> GatewayServiceOutcome {
        do {
            let action = try await perform("gateway.service.install", [:])
            switch action.outcome {
            case "installed", "already_installed": return .done(action.status.info)
            case "unsupported": return .unsupported(action.reason ?? Self.couldNotInstall)
            default: return .failed(action.reason ?? Self.couldNotInstall)
            }
        } catch {
            return .failed(Self.couldNotInstall)
        }
    }

    private func perform(_ method: String, _ params: [String: JSONValue]) async throws -> GatewayServiceActionWire {
        let result = try await gateway.call(method, params)
        return try gateway.decoded(GatewayServiceActionWire.self, result)
    }

    private func awaitNewInstance(replacing previous: String?) async -> GatewayServiceOutcome {
        var last: GatewayServiceInfo?
        for _ in 0..<pollLimit {
            do { try await sleep(pollInterval) } catch { return .pending(last) }
            guard let info = try? await status() else { continue }
            last = info
            if info.isRunning, let instance = info.instance, instance != previous { return .done(info) }
        }
        return .pending(last)
    }

    static let couldNotRestart = "Pal couldn't restart."
    static let couldNotInstall = "Pal couldn't install the service."
}
