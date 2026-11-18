import Foundation

public enum SetupStatusClass: String, Sendable, CaseIterable, Equatable {
    case offline
    case gatewayOutdated = "gateway_outdated"
    case vendorRefusedValue = "invalid_token"
    case needsReauth = "needs_reauth"
    case forbidden
    case signInInProgress = "oauth_in_progress"
    case invalidRedirect = "invalid_redirect_uri"
    case internalFault = "internal"

    static let byCode: [String: SetupStatusClass] = [
        "offline": .offline, "timed_out": .offline, "unreachable": .offline, "provider_unreachable": .offline,
        "gateway_outdated": .gatewayOutdated, "unsupported": .gatewayOutdated,
        "invalid_token": .vendorRefusedValue, "credential_rejected": .vendorRefusedValue,
        "credential_expired": .vendorRefusedValue, "invalid_client": .vendorRefusedValue,
        "needs_reauth": .needsReauth, "revoked": .needsReauth, "auth_required": .needsReauth,
        "forbidden": .forbidden, "not_owner": .forbidden,
        "oauth_in_progress": .signInInProgress,
        "invalid_redirect_uri": .invalidRedirect, "invalid_client_metadata": .invalidRedirect,
    ]

    public static func classify(code: String) -> SetupStatusClass {
        byCode[code.lowercased()] ?? .internalFault
    }
}

public struct SetupStatus: Sendable, Equatable {
    public var kind: SetupStatusClass
    public var title: String
    public var reason: String
    public var actionTitle: String
    public var code: String
    public var method: String?
    public var trace: String?
    public var gatewayVersion: String?

    public init(
        code: String, method: String? = nil, trace: String? = nil, gatewayVersion: String? = nil,
        subject: String? = nil, valueName: String = "token", device: String = "device"
    ) {
        let kind = SetupStatusClass.classify(code: code)
        let name = subject ?? String(localized: "This app")
        self.kind = kind
        self.code = code
        self.method = method
        self.trace = trace
        self.gatewayVersion = gatewayVersion
        switch kind {
        case .offline:
            title = String(localized: "Can't reach your Pal")
            reason = String(localized: "Check that your computer is on and awake, then try again.")
            actionTitle = String(localized: "Try again")
        case .gatewayOutdated:
            title = String(localized: "Your Pal needs an update")
            reason = String(localized: "Update Pal on your computer to set this up from here.")
            actionTitle = String(localized: "Check again")
        case .vendorRefusedValue:
            title = subject.map { String(localized: "\($0) did not accept that \(valueName)") } ?? String(localized: "That \(valueName) was not accepted")
            reason = subject.map { String(localized: "Copy the \(valueName) again from \($0) and paste it here.") }
                ?? String(localized: "Copy the \(valueName) again and paste it here.")
            actionTitle = String(localized: "Edit \(valueName)")
        case .needsReauth:
            title = String(localized: "Sign-in expired")
            reason = String(localized: "\(name) needs you to sign in again.")
            actionTitle = String(localized: "Reconnect")
        case .forbidden:
            title = String(localized: "Only the owner can do this")
            reason = String(localized: "This step changes your Pal's settings. Ask the owner to do it.")
            actionTitle = String(localized: "Close")
        case .signInInProgress:
            title = String(localized: "A sign-in was already open")
            reason = String(localized: "Pal closed the old one. Start again.")
            actionTitle = String(localized: "Connect")
        case .invalidRedirect:
            title = String(localized: "\(name) would not accept this \(device)'s address")
            reason = String(localized: "\(name) only allows sign-in on your own computer, and Pal could not open one here.")
            actionTitle = String(localized: "Try again")
        case .internalFault:
            title = String(localized: "Pal could not finish")
            reason = String(localized: "Something on your Pal failed. The code below helps support find it.")
            actionTitle = String(localized: "Try again")
        }
    }

    public var symbol: String {
        switch kind {
        case .offline: "wifi.slash"
        case .gatewayOutdated: "arrow.down.circle"
        case .forbidden: "lock"
        default: "exclamationmark.triangle"
        }
    }

    public func detailsText(appBuild: String?) -> String {
        var lines = ["code: \(code)"]
        if let method { lines.append("method: \(method)") }
        if let trace { lines.append("trace: \(trace)") }
        let builds = [appBuild.map { "app: \($0)" }, gatewayVersion.map { "gateway \($0)" }].compactMap { $0 }
        if !builds.isEmpty { lines.append(builds.joined(separator: " · ")) }
        return lines.joined(separator: "\n")
    }
}
