import Foundation
#if canImport(UIKit)
import UIKit
#endif

public enum ConnectorPlatform: Sendable, Equatable, CaseIterable {
    case iPhone
    case iPad
    case mac

    @MainActor
    public static var current: ConnectorPlatform {
        #if os(macOS)
        return .mac
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? .iPad : .iPhone
        #endif
    }

    public var signInRoutes: [OAuthSignInRoute] {
        switch self {
        case .mac: return [.automaticReturn, .pasteAddress]
        case .iPhone, .iPad: return [.pasteAddress]
        }
    }

    public var returnsAutomatically: Bool { signInRoutes.contains(.automaticReturn) }
}

public enum OAuthSignInRoute: Sendable, Equatable {
    case automaticReturn
    case pasteAddress
}

public enum ConnectorCardState: Sendable, Equatable {
    case connect
    case connecting
    case connected
    case failed(String)
    case reconnect(reason: String?)

    public var isReconnect: Bool {
        if case .reconnect = self { return true }
        return false
    }
}

public struct ConnectorCardInput: Sendable, Equatable {
    public var connection: ConnectAppState
    public var isBusy: Bool
    public var failureReason: String?
    public var authReason: String?

    public init(connection: ConnectAppState, isBusy: Bool = false, failureReason: String? = nil, authReason: String? = nil) {
        self.connection = connection
        self.isBusy = isBusy
        self.failureReason = failureReason
        self.authReason = authReason
    }

    public init(app: ConnectApp, isBusy: Bool = false, failureReason: String? = nil) {
        self.init(connection: app.state, isBusy: isBusy, failureReason: failureReason, authReason: app.authReason)
    }
}

extension ConnectorCardState {
    public static func resolve(_ input: ConnectorCardInput) -> ConnectorCardState {
        if input.isBusy { return .connecting }
        switch input.connection {
        case .connected:
            return .connected
        case .needsAuthorization:
            return .reconnect(reason: cleaned(input.authReason))
        case .disconnected:
            if let reason = input.failureReason, !reason.isEmpty { return .failed(reason) }
            return .connect
        }
    }

    static func cleaned(_ text: String?) -> String? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
