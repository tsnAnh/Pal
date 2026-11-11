import CryptoKit
import Foundation
import PalDiagnostics
import PalProtocol
import PalTransport

public enum ComputerFailure: Error, Equatable, Sendable {
    case unavailable
    case notSetUp
    case lowMemory
    case staleViewer
    case notAllowed
    case offline

    public static func classify(_ error: any Error) -> ComputerFailure {
        if let failure = error as? ComputerFailure { return failure }
        guard case GatewayTransportError.rpc(let rpc) = error else { return .offline }
        if rpc.data?["code"]?.stringValue == "viewer_mismatch" { return .staleViewer }
        switch rpc.reasonCode ?? rpc.message {
        case "permission_denied", "profile_mismatch": return .notAllowed
        default: return .unavailable
        }
    }
}

public struct ComputerLeaseSnapshot: Sendable, Equatable {
    public let humanHolds: Bool
    public let ask: String?
    public let askAt: Double?
    private let holderHash: String?

    public func isHeld(by viewerID: String) -> Bool {
        humanHolds && holderHash == Self.hash(of: viewerID)
    }

    static func hash(of viewerID: String) -> String {
        SHA256.hash(data: Data(viewerID.utf8)).map { String(format: "%02x", $0) }.joined().prefix(12).description
    }

    init(_ wire: DisplayLeaseWire?) {
        humanHolds = wire?.holder == "human"
        holderHash = wire?.viewerHash
        let ask = wire?.ask ?? ""
        self.ask = ask.isEmpty ? nil : ask
        askAt = ask.isEmpty ? nil : wire?.askAt
    }
}

public struct ComputerObservation: Sendable, Equatable {
    public let ticket: String
    public let path: String
    public let viewerID: String
    public let lease: ComputerLeaseSnapshot
}

public struct ComputerService: Sendable {
    private let gateway: BotsGateway

    public init(gateway: BotsGateway) {
        self.gateway = gateway
    }

    public func prepare(for name: String, viewerID: String? = nil) async throws -> ComputerObservation {
        do {
            let status = try gateway.decoded(DisplayStatusWire.self, try await gateway.scoped("display.status", profile: name))
            if !status.running { try await start(name, status) }
            var params: [String: JSONValue] = [:]
            if let viewerID { params["viewer_id"] = .string(viewerID) }
            let wire = try gateway.decoded(DisplayObserveWire.self, try await gateway.scoped("display.observe", profile: name, params))
            return ComputerObservation(ticket: wire.ticket, path: wire.path, viewerID: wire.viewerID, lease: ComputerLeaseSnapshot(wire.lease))
        } catch {
            throw ComputerFailure.classify(error)
        }
    }

    public func takeControl(for name: String, viewerID: String) async throws -> ComputerLeaseSnapshot {
        do {
            let result = try await gateway.scoped("display.lease.acquire", profile: name, ["viewer_id": .string(viewerID)])
            return ComputerLeaseSnapshot(try gateway.decoded(DisplayLeaseResultWire.self, result).lease)
        } catch {
            throw ComputerFailure.classify(error)
        }
    }

    public func handBack(for name: String, viewerID: String, resolvingAskAt askAt: Double?) async throws -> ComputerLeaseSnapshot {
        do {
            let released = try await gateway.scoped("display.lease.release", profile: name, ["viewer_id": .string(viewerID)])
            var lease = try gateway.decoded(DisplayLeaseResultWire.self, released).lease
            if let askAt {
                let resolved = try await gateway.scoped("display.lease.resolve", profile: name, ["ask_at": .double(askAt)])
                lease = try gateway.decoded(DisplayLeaseResultWire.self, resolved).lease
            }
            return ComputerLeaseSnapshot(lease)
        } catch {
            throw ComputerFailure.classify(error)
        }
    }

    private func start(_ name: String, _ status: DisplayStatusWire) async throws {
        guard status.supported else { throw ComputerFailure.unavailable }
        guard status.installed else { throw ComputerFailure.notSetUp }
        guard status.blocker == nil else { throw ComputerFailure.lowMemory }
        _ = try await gateway.scoped("display.start", profile: name)
    }
}
