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
    case reconnect
    case signInOnMac
}

public struct ConnectorCardInput: Sendable, Equatable {
    public var connection: ConnectAppState
    public var isBusy: Bool
    public var failureReason: String?
    public var requiresMacSignIn: Bool

    public init(connection: ConnectAppState, isBusy: Bool = false, failureReason: String? = nil, requiresMacSignIn: Bool = false) {
        self.connection = connection
        self.isBusy = isBusy
        self.failureReason = failureReason
        self.requiresMacSignIn = requiresMacSignIn
    }

    public init(app: ConnectApp, isBusy: Bool = false, failureReason: String? = nil) {
        self.init(connection: app.state, isBusy: isBusy, failureReason: failureReason, requiresMacSignIn: app.requiresMacSignIn)
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
            return cannotSignInHere ? .signInOnMac : .reconnect
        case .disconnected:
            if cannotSignInHere { return .signInOnMac }
            if let reason = input.failureReason, !reason.isEmpty { return .failed(reason) }
            return .connect
        }
    }
}
