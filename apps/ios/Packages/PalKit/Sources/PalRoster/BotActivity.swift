import Foundation

public enum GatewayLink: Sendable, Equatable {
    case connected
    case reconnecting
    case offline
}

public enum LiveSessionStatus: String, Sendable, Equatable, Decodable {
    case working
    case waiting
    case starting
    case idle
    case unknown

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = LiveSessionStatus(rawValue: raw) ?? .unknown
    }
}

public struct BotLiveState: Sendable, Equatable {
    public var sessions: [LiveSessionStatus]
    public var workerLastActive: TimeInterval?

    public init(sessions: [LiveSessionStatus] = [], workerLastActive: TimeInterval? = nil) {
        self.sessions = sessions
        self.workerLastActive = workerLastActive
    }
}

public enum BotActivity: Sendable, Equatable {
    case offline
    case idle
    case working
    case needsInput

    public static let workerLivenessWindow: TimeInterval = 150

    public static func derive(link: GatewayLink, live: BotLiveState?, hasLocalPrompt: Bool, now: Date) -> BotActivity {
        guard link == .connected else { return .offline }
        let sessions = live?.sessions ?? []
        if hasLocalPrompt || sessions.contains(.waiting) { return .needsInput }
        if sessions.contains(where: { $0 == .working || $0 == .starting }) || workerIsLive(live, now: now) { return .working }
        return .idle
    }

    private static func workerIsLive(_ live: BotLiveState?, now: Date) -> Bool {
        guard let stamp = live?.workerLastActive else { return false }
        return now.timeIntervalSince1970 - stamp < workerLivenessWindow
    }

    public var accessibilityValue: String {
        switch self {
        case .offline: "offline"
        case .idle: "idle"
        case .working: "working"
        case .needsInput: "needs-input"
        }
    }

    public var isLive: Bool {
        switch self {
        case .working, .needsInput: true
        case .offline, .idle: false
        }
    }
}
