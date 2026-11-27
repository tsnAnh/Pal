import Foundation

public enum SetupStatusClass: String, Sendable, CaseIterable, Equatable {
    case offline
    case gatewayOutdated = "gateway_outdated"
    case vendorRefusedValue = "invalid_token"
    case needsReauth = "needs_reauth"
    case forbidden
    case signInInProgress = "oauth_in_progress"
    case invalidRedirect = "invalid_redirect_uri"
    case serverUnreachable = "server_unreachable"
    case notMcpServer = "not_mcp"
    case signInIncomplete = "sign_in_failed"
    case explorerAccessNeeded = "explorer_access_needed"
    case internalFault = "internal"

    private static let incompleteCodes = [
        "sign_in_failed", "access_denied", "sign_in_expired", "sign_in_timed_out", "browser_unavailable", "discovery_failed", "listener_failed",
        "state_mismatch", "token_exchange_failed", "unsupported_grant_type", "gateway_rejected", "server_add_failed", "account_name",
    ]

    static let byCode: [String: SetupStatusClass] = {
        var table: [String: SetupStatusClass] = [
            "offline": .offline, "timed_out": .offline, "unreachable": .offline, "provider_unreachable": .offline,
            "gateway_outdated": .gatewayOutdated, "unsupported": .gatewayOutdated,
            "invalid_token": .vendorRefusedValue, "credential_rejected": .vendorRefusedValue,
            "credential_expired": .vendorRefusedValue, "invalid_client": .vendorRefusedValue,
            "needs_reauth": .needsReauth, "revoked": .needsReauth, "auth_required": .needsReauth,
            "forbidden": .forbidden, "not_owner": .forbidden,
            "oauth_in_progress": .signInInProgress, "handshake_used": .signInInProgress,
            "invalid_redirect_uri": .invalidRedirect, "invalid_client_metadata": .invalidRedirect,
            "server_unreachable": .serverUnreachable, "mcp_unreachable": .serverUnreachable, "not_mcp": .notMcpServer,
            "explorer_access_needed": .explorerAccessNeeded,
        ]
        for code in incompleteCodes { table[code] = .signInIncomplete }
        return table
    }()

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
    public var link: SetupLink?

    public init(
        kind: SetupStatusClass = .internalFault, title: String, reason: String, actionTitle: String, code: String,
        trace: String? = nil
    ) {
        self.kind = kind
        self.title = title
        self.reason = reason
        self.actionTitle = actionTitle
        self.code = code
        self.trace = trace
    }

    public init(
        code: String, method: String? = nil, trace: String? = nil, gatewayVersion: String? = nil,
        subject: String? = nil, valueName: String = "token", device: String = "device", detail: String? = nil
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
        case .serverUnreachable, .notMcpServer, .explorerAccessNeeded:
            let copy = Self.serverCopy(kind, name: name)
            (title, reason, actionTitle) = (copy.title, copy.reason, copy.actionTitle)
        case .signInIncomplete:
            title = String(localized: "Sign-in did not finish")
            reason = detail ?? String(localized: "The sign-in could not be completed. Try again.")
            actionTitle = String(localized: "Try again")
        case .internalFault:
            title = String(localized: "Pal could not finish")
            reason = String(localized: "Something on your Pal failed. The code below helps support find it.")
            actionTitle = String(localized: "Try again")
        }
    }

    public static var tookTooLong: SetupStatus {
        SetupStatus(
            title: String(localized: "This is taking too long"), reason: String(localized: "Nothing happened in time. Try again."),
            actionTitle: String(localized: "Retry"), code: "timed_out"
        )
    }

    private struct ServerCopy {
        var title: String
        var reason: String
        var actionTitle = String(localized: "Enter the address again")
    }

    private static func serverCopy(_ kind: SetupStatusClass, name: String) -> ServerCopy {
        if kind == .explorerAccessNeeded {
            return ServerCopy(
                title: String(localized: "Apply for Explorer access"),
                reason: String(localized: "Google has not approved this project yet. The review is automatic and takes minutes. Apply, then check again."),
                actionTitle: String(localized: "Open Google Cloud")
            )
        }
        if kind == .serverUnreachable {
            return ServerCopy(
                title: String(localized: "Pal could not reach \(name)"),
                reason: String(localized: "Check that it is running and that its address is still right.")
            )
        }
        return ServerCopy(
            title: String(localized: "\(name) did not answer like an MCP server"),
            reason: String(localized: "Check the address and the port.")
        )
    }

    public var symbol: String {
        switch kind {
        case .offline, .serverUnreachable: "wifi.slash"
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
