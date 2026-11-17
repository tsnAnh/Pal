import Foundation

public enum ConnectAppStatus: Sendable, Equatable {
    case connected
    case needsSignIn
    case notConnected

    public init(_ state: ConnectAppState) {
        switch state {
        case .connected: self = .connected
        case .needsAuthorization: self = .needsSignIn
        case .disconnected: self = .notConnected
        }
    }

    public var title: String {
        switch self {
        case .connected: String(localized: "Connected")
        case .needsSignIn: String(localized: "Needs sign-in")
        case .notConnected: String(localized: "Not connected")
        }
    }
}
