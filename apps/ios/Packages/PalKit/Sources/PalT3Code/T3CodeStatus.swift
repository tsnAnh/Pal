import Foundation
import PalConnect

public enum T3SignInReason: Sendable, Equatable {
    case rejected
    case expired

    public var text: String {
        switch self {
        case .rejected: "T3 Code asked you to sign in again"
        case .expired: "Your T3 Code sign-in ran out"
        }
    }
}

public enum T3Failure: Sendable, Equatable {
    case signIn(McpOAuthError)
    case registration
    case storage

    public var text: String {
        switch self {
        case .signIn(let error): error.reason
        case .registration: "Your Pal couldn't be told about T3 Code. Try again"
        case .storage: "Pal couldn't keep the T3 Code sign-in on this Mac"
        }
    }
}

public enum T3CodeConnection: Sendable, Equatable {
    case notInstalled
    case notRunning
    case signedOut
    case connecting
    case connected
    case needsSignIn(T3SignInReason)
    case failed(T3Failure)
}

public enum T3CodeEvent: Sendable, Equatable {
    case installationChecked(Bool)
    case runtimeSeen
    case runtimeGone
    case tokenFound(expired: Bool)
    case tokenMissing
    case signInStarted
    case signInSucceeded
    case signInCancelled
    case signInFailed(T3Failure)
    case registrationFailed
    case registrationSucceeded
    case unauthorized
    case disconnectTapped
}

public struct T3CodeStatus: Sendable, Equatable {
    public enum Credential: Sendable, Equatable {
        case none
        case saved
        case unusable(T3SignInReason)
    }

    public enum Attempt: Sendable, Equatable {
        case idle
        case signingIn
        case failed(T3Failure)
    }

    public var installed: Bool
    public var running: Bool
    public var credential: Credential
    public var attempt: Attempt

    public init(installed: Bool = false, running: Bool = false, credential: Credential = .none, attempt: Attempt = .idle) {
        self.installed = installed
        self.running = running
        self.credential = credential
        self.attempt = attempt
    }

    public var connection: T3CodeConnection {
        guard installed || running else { return .notInstalled }
        guard running else { return .notRunning }
        switch attempt {
        case .signingIn: return .connecting
        case .failed(let failure): return .failed(failure)
        case .idle: break
        }
        switch credential {
        case .none: return .signedOut
        case .unusable(let reason): return .needsSignIn(reason)
        case .saved: return .connected
        }
    }

    public mutating func apply(_ event: T3CodeEvent) {
        switch event {
        case .installationChecked(let installed):
            self.installed = installed
        case .runtimeSeen:
            running = true
        case .runtimeGone:
            running = false
            attempt = .idle
        case .tokenFound(let expired):
            credential = expired ? .unusable(.expired) : .saved
        case .tokenMissing:
            credential = .none
        case .signInStarted:
            attempt = .signingIn
        case .signInSucceeded:
            credential = .saved
            attempt = .idle
        case .signInCancelled:
            attempt = .idle
        case .signInFailed(let failure):
            attempt = .failed(failure)
        case .registrationFailed:
            attempt = .failed(.registration)
        case .registrationSucceeded:
            if attempt == .failed(.registration) { attempt = .idle }
        case .unauthorized:
            credential = .unusable(.rejected)
            attempt = .idle
        case .disconnectTapped:
            credential = .none
            attempt = .idle
        }
    }

    public func applying(_ event: T3CodeEvent) -> T3CodeStatus {
        var next = self
        next.apply(event)
        return next
    }
}

public struct T3CodeRowPresentation: Sendable, Equatable {
    public enum Action: Sendable, Equatable {
        case openApp
        case connect
        case disconnect
    }

    public static let title = "T3 Code"
    public static let subtitle = "Send coding work to T3 Code on this Mac"

    public let summary: String
    public let buttonTitle: String?
    public let action: Action?
    public let isBusy: Bool

    public init(_ connection: T3CodeConnection) {
        switch connection {
        case .notInstalled: self.init(summary: "Install T3 Code on this Mac", buttonTitle: nil, action: nil)
        case .notRunning: self.init(summary: "Open T3 Code to connect", buttonTitle: "Open T3 Code", action: .openApp)
        case .signedOut: self.init(summary: Self.subtitle, buttonTitle: "Connect", action: .connect)
        case .connecting: self.init(summary: "Waiting for you to approve in your browser", buttonTitle: nil, action: nil, isBusy: true)
        case .connected: self.init(summary: "Connected", buttonTitle: "Disconnect", action: .disconnect)
        case .needsSignIn(let reason): self.init(summary: reason.text, buttonTitle: "Sign in again", action: .connect)
        case .failed(let failure): self.init(summary: failure.text, buttonTitle: "Try again", action: .connect)
        }
    }

    private init(summary: String, buttonTitle: String?, action: Action?, isBusy: Bool = false) {
        self.summary = summary
        self.buttonTitle = buttonTitle
        self.action = action
        self.isBusy = isBusy
    }
}
