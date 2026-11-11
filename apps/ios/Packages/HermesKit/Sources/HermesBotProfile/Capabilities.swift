import Foundation
import HermesProtocol
import HermesTransport

public enum CapabilityState: Sendable, Equatable {
    case on
    case off
    case unavailable

    init(wire: String?) {
        switch wire {
        case "on": self = .on
        case "off": self = .off
        default: self = .unavailable
        }
    }
}

public enum CapabilityIndicator: Sendable, Equatable {
    case on
    case limited
    case off
    case unavailable
}

public struct CapabilityRow: Sendable, Equatable, Identifiable {
    public let id: String
    public let label: String
    public let state: CapabilityState
    public let reason: String?
    public let keyName: String?
    public let setting: String?

    public init(id: String, label: String, state: CapabilityState, reason: String? = nil, keyName: String? = nil, setting: String? = nil) {
        self.id = id
        self.label = label
        self.state = state
        self.reason = Self.text(reason)
        self.keyName = Self.text(keyName)
        self.setting = Self.text(setting)
    }

    init?(_ wire: CapabilityRowWire) {
        guard let id = Self.text(wire.id) else { return nil }
        self.init(id: id, label: Self.text(wire.label) ?? id, state: CapabilityState(wire: wire.state), reason: wire.reason, keyName: wire.keyName, setting: wire.setting)
    }

    public var indicator: CapabilityIndicator {
        switch state {
        case .on: reason == nil ? .on : .limited
        case .off: .off
        case .unavailable: .unavailable
        }
    }

    public var stateWord: String {
        switch indicator {
        case .on: "On"
        case .limited: "Limited"
        case .off: "Off"
        case .unavailable: "Unavailable"
        }
    }

    public var shownKeyName: String? {
        switch indicator {
        case .limited, .off: keyName
        case .on, .unavailable: nil
        }
    }

    public var terminalHint: String? {
        shownKeyName.map { "Set \($0) from your terminal." }
    }

    private static func text(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

public struct CapabilitiesService: Sendable {
    private let gateway: BotsGateway

    public init(gateway: BotsGateway) {
        self.gateway = gateway
    }

    public func status(profile: String) async throws -> [CapabilityRow] {
        do {
            let result = try await gateway.scoped("capabilities.status", profile: profile)
            return try gateway.decoded(CapabilitiesStatusWire.self, result).capabilities.compactMap(CapabilityRow.init)
        } catch {
            throw BotsError.surface(error)
        }
    }
}
