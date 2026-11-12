import Foundation
import PalProtocol
import PalTransport

public struct GatewayLimit: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let value: String
    public let detail: String?

    static let unknown = "Unknown"

    private static let titles: [String: String] = [
        "enabled": "Bot loop guard",
        "max_hops": "Messages per bot exchange",
        "max_events": "Bot messages per window",
        "window_seconds": "Window",
        "cooldown_seconds": "Cooldown",
        "bot_replies_expect_reply": "Answer replies from bots",
    ]

    init?(_ wire: JSONValue) {
        guard let key = wire["key"]?.stringValue, !key.isEmpty else { return nil }
        let name = key.split(separator: ".").last.map(String.init) ?? key
        id = key
        title = Self.titles[name] ?? name.replacingOccurrences(of: "_", with: " ").capitalized
        value = Self.text(wire["value"], seconds: name.hasSuffix("_seconds"))
        var notes: [String] = []
        switch wire["source"]?.stringValue {
        case "config": notes.append("Set in your settings")
        case "default": notes.append("Standard value")
        default: break
        }
        if wire["clamped"]?.boolValue == true { notes.append("Capped at the allowed maximum") }
        detail = notes.isEmpty ? nil : notes.joined(separator: ", ")
    }

    private static func text(_ value: JSONValue?, seconds: Bool) -> String {
        if let flag = value?.boolValue { return flag ? "On" : "Off" }
        if let whole = value?.intValue { return seconds ? "\(whole) s" : String(whole) }
        if case .double(let number)? = value, number.isFinite { return seconds ? "\(number) s" : String(number) }
        return unknown
    }
}

public enum GatewayLimitsFailure: Error, Sendable, Equatable {
    case unsupported
    case unavailable

    static func classify(_ error: any Error) -> GatewayLimitsFailure {
        if case GatewayTransportError.rpc(let rpc) = error, rpc.code == -32601 { return .unsupported }
        return .unavailable
    }
}

public struct GatewayLimitsClient: Sendable {
    private let gateway: BotsGateway

    public init(gateway: BotsGateway) {
        self.gateway = gateway
    }

    public func limits() async throws -> [GatewayLimit] {
        let result: JSONValue
        do {
            result = try await gateway.call("gateway.guards.status", [:])
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw GatewayLimitsFailure.classify(error)
        }
        guard let rows = result["guards"]?.arrayValue else { throw GatewayLimitsFailure.unavailable }
        return rows.compactMap(GatewayLimit.init)
    }
}
