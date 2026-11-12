import Foundation

public enum ConnectorPlatform: Sendable, Equatable {
    case iPhone
    case mac

    public static var current: ConnectorPlatform {
        #if os(macOS)
        .mac
        #else
        .iPhone
        #endif
    }
}

public enum ConnectorCardState: Sendable, Equatable {
    case connect
    case connecting
    case connected
    case failed(String)
    case reconnect(reason: String?)
    case signInOnMac(reason: String?)

    public var isReconnect: Bool {
        if case .reconnect = self { return true }
        return false
    }
}

public struct ConnectorCardInput: Sendable, Equatable {
    public var connection: ConnectAppState
    public var isBusy: Bool
    public var failureReason: String?
    public var requiresMacSignIn: Bool
    public var authReason: String?

    public init(connection: ConnectAppState, isBusy: Bool = false, failureReason: String? = nil, requiresMacSignIn: Bool = false, authReason: String? = nil) {
        self.connection = connection
        self.isBusy = isBusy
        self.failureReason = failureReason
        self.requiresMacSignIn = requiresMacSignIn
        self.authReason = authReason
    }

    public init(app: ConnectApp, isBusy: Bool = false, failureReason: String? = nil) {
        self.init(connection: app.state, isBusy: isBusy, failureReason: failureReason, requiresMacSignIn: app.requiresMacSignIn, authReason: app.authReason)
    }
}

extension ConnectorCardState {
    public static func resolve(_ input: ConnectorCardInput, platform: ConnectorPlatform) -> ConnectorCardState {
        if input.isBusy { return .connecting }
        let cannotSignInHere = input.requiresMacSignIn && platform == .iPhone
        switch input.connection {
        case .connected:
            return .connected
        case .needsAuthorization:
            let reason = cleaned(input.authReason)
            return cannotSignInHere ? .signInOnMac(reason: reason) : .reconnect(reason: reason)
        case .disconnected:
            if cannotSignInHere { return .signInOnMac(reason: nil) }
            if let reason = input.failureReason, !reason.isEmpty { return .failed(reason) }
            return .connect
        }
    }

    static func cleaned(_ text: String?) -> String? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
