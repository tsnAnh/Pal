import Foundation
import PalProtocol
import PalTransport

public enum HostUpdateBlocker: String, Sendable, Equatable {
    case turnRunning = "turn_running"
    case dirtyInstall = "dirty_install"
    case updateRunning = "update_running"
    case noNetwork = "no_network"
}

public enum HostUpdatePhase: String, Sendable, Equatable, CaseIterable {
    case preparing, downloading, applying, installing, restarting, finished
}

public struct HostUpdateCheck: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case upToDate
        case updateAvailable
        case unknown
    }

    public let version: String
    public let status: Status
    public let commitsBehind: Int?
    public let offline: Bool
    public let releaseNotesURL: URL?
    public let activeRuns: Int
    public let blockers: [HostUpdateBlocker]

    public var turnIsRunning: Bool { blockers.contains(.turnRunning) }
    public var hardBlockers: [HostUpdateBlocker] { blockers.filter { $0 != .turnRunning } }
    public var canUpdate: Bool { status == .updateAvailable && hardBlockers.isEmpty }
}

public enum HostUpdateFailure: Sendable, Equatable {
    case noNetwork(lastPhase: HostUpdatePhase?)
    case failed(lastPhase: HostUpdatePhase?, oldVersionRunning: Bool)
    case needsRecovery
    case interrupted(lastPhase: HostUpdatePhase?)
    case notStarted
}

public enum HostUpdateProgress: Sendable, Equatable {
    case running(phase: HostUpdatePhase?, tail: [String])
    case gatewayRestarting(lastPhase: HostUpdatePhase?, tail: [String])
    case succeeded(version: String)
    case failed(HostUpdateFailure, tail: [String])
    case didNotComeBack(lastPhase: HostUpdatePhase?)

    public var isFinal: Bool {
        switch self {
        case .running, .gatewayRestarting: false
        case .succeeded, .failed, .didNotComeBack: true
        }
    }
}

public enum HostUpdateStart: Sendable, Equatable {
    case started
    case alreadyRunning
    case refused([HostUpdateBlocker])
    case failed
}

struct HostUpdateCheckWire: Decodable {
    let version: String
    let status: String
    let commitsBehind: Int?
    let error: String?
    let releaseNotesUrl: String?
    let activeRuns: Int
    let blockers: [String]

    enum CodingKeys: String, CodingKey {
        case version, status, error, blockers
        case commitsBehind = "commits_behind"
        case releaseNotesUrl = "release_notes_url"
        case activeRuns = "active_runs"
    }

    var check: HostUpdateCheck {
        HostUpdateCheck(
            version: version,
            status: status == "up_to_date" ? .upToDate : status == "update_available" ? .updateAvailable : .unknown,
            commitsBehind: commitsBehind, offline: error == "no_network",
            releaseNotesURL: releaseNotesUrl.flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil },
            activeRuns: activeRuns, blockers: blockers.compactMap(HostUpdateBlocker.init(rawValue:)))
    }
}

struct HostUpdateStateWire: Decodable {
    let state: String
    let phase: String?
    let tail: [String]
    let failure: String?
    let leftBehind: String?
    let version: String

    enum CodingKeys: String, CodingKey {
        case state, phase, tail, failure, version
        case leftBehind = "left_behind"
    }

    var lastPhase: HostUpdatePhase? { phase.flatMap(HostUpdatePhase.init(rawValue:)) }

    var progress: HostUpdateProgress {
        switch state {
        case "succeeded": .succeeded(version: version)
        case "needs_recovery": .failed(.needsRecovery, tail: tail)
        case "failed": .failed(failureKind, tail: tail)
        default: .running(phase: lastPhase, tail: tail)
        }
    }

    private var failureKind: HostUpdateFailure {
        switch failure {
        case "no_network": .noNetwork(lastPhase: lastPhase)
        case "interrupted": .interrupted(lastPhase: lastPhase)
        case "not_started": .notStarted
        default: .failed(lastPhase: lastPhase, oldVersionRunning: leftBehind != "tree_needs_recovery")
        }
    }
}

struct HostUpdateApplyWire: Decodable {
    let outcome: String
    let blockers: [String]
}

public struct HostUpdateClient: Sendable {
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    public static let defaultPollInterval: Duration = .seconds(2)
    public static let defaultDownLimit = 90
    public static let defaultRunLimit = 900

    private let gateway: BotsGateway
    private let sleep: Sleep
    private let pollInterval: Duration
    private let downLimit: Int
    private let runLimit: Int

    public init(
        gateway: BotsGateway,
        pollInterval: Duration = HostUpdateClient.defaultPollInterval,
        downLimit: Int = HostUpdateClient.defaultDownLimit,
        runLimit: Int = HostUpdateClient.defaultRunLimit,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
        self.gateway = gateway
        self.pollInterval = pollInterval
        self.downLimit = downLimit
        self.runLimit = runLimit
        self.sleep = sleep
    }

    public func check() async throws -> HostUpdateCheck {
        do {
            let result = try await gateway.call("host.update.check")
            return try gateway.decoded(HostUpdateCheckWire.self, result).check
        } catch {
            throw BotsError.surface(error)
        }
    }

    public func start(confirmTurns: Bool) async -> HostUpdateStart {
        do {
            let result = try await gateway.call("host.update.apply", confirmTurns ? ["confirm_turns": .bool(true)] : [:])
            let wire = try gateway.decoded(HostUpdateApplyWire.self, result)
            switch wire.outcome {
            case "started": return .started
            case "already_running": return .alreadyRunning
            case "refused": return .refused(wire.blockers.compactMap(HostUpdateBlocker.init(rawValue:)))
            default: return .failed
            }
        } catch {
            return .failed
        }
    }

    public func result() async -> HostUpdateProgress? {
        guard let state = try? await poll() else { return nil }
        return state.progress
    }

    public func follow(onProgress: @Sendable (HostUpdateProgress) -> Void = { _ in }) async -> HostUpdateProgress {
        var lastPhase: HostUpdatePhase?
        var tail: [String] = []
        var downPolls = 0
        for _ in 0..<runLimit {
            do { try await sleep(pollInterval) } catch { return .didNotComeBack(lastPhase: lastPhase) }
            guard let state = try? await poll() else {
                downPolls += 1
                if downPolls >= downLimit { return .didNotComeBack(lastPhase: lastPhase) }
                onProgress(.gatewayRestarting(lastPhase: lastPhase, tail: tail))
                continue
            }
            downPolls = 0
            lastPhase = state.lastPhase ?? lastPhase
            tail = state.tail
            let progress: HostUpdateProgress = state.state == "idle" ? .didNotComeBack(lastPhase: lastPhase) : state.progress
            onProgress(progress)
            if progress.isFinal { return progress }
        }
        return .didNotComeBack(lastPhase: lastPhase)
    }

    private func poll() async throws -> HostUpdateStateWire {
        let result = try await gateway.call("host.update.status")
        return try gateway.decoded(HostUpdateStateWire.self, result)
    }
}
