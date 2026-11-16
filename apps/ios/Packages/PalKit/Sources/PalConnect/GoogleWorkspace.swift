import Foundation
import PalProtocol
import PalTransport

public enum GoogleService: String, CaseIterable, Codable, Sendable, Hashable {
    case gmail
    case calendar
    case drive
    case contacts
    case sheets
    case docs

    public var displayName: String {
        switch self {
        case .gmail: "Gmail"
        case .calendar: "Calendar"
        case .drive: "Drive"
        case .contacts: "Contacts"
        case .sheets: "Sheets"
        case .docs: "Docs"
        }
    }

    public var hasWriteOptIn: Bool { self != .contacts }
}

public enum GoogleReauthReason: String, CaseIterable, Sendable, Equatable {
    case tokenMissing = "token_missing"
    case tokenUnreadable = "token_unreadable"
    case revoked
    case clientRejected = "client_rejected"
    case unknown

    public var plainReason: String {
        switch self {
        case .tokenMissing: "Your Google sign-in is missing. Sign in again."
        case .tokenUnreadable: "Your saved Google sign-in can't be read. Sign in again."
        case .revoked: "Google access was removed. Sign in again to give it back."
        case .clientRejected: "Google no longer accepts the saved client. Sign in again, or set up the client again."
        case .unknown: "Your Google sign-in needs attention. Sign in again."
        }
    }
}

extension GoogleReauthReason {
    public init(signIn reason: ServiceSignInReason) {
        switch reason {
        case .missing: self = .tokenMissing
        case .expired: self = .tokenUnreadable
        case .revoked: self = .revoked
        case .unknown: self = .unknown
        }
    }
}

public struct GoogleWorkspaceStatus: Sendable, Equatable, Decodable {
    public enum State: String, Sendable, Equatable {
        case notConfigured = "not_configured"
        case needsSignIn = "needs_sign_in"
        case signedIn = "signed_in"
        case reauthNeeded = "reauth_needed"
    }

    public var state: State
    public var email: String?
    public var services: [GoogleService]
    public var writeServices: [GoogleService]
    public var reauthReason: GoogleReauthReason?

    public init(
        state: State, email: String? = nil, services: [GoogleService] = [], writeServices: [GoogleService] = [],
        reauthReason: GoogleReauthReason? = nil
    ) {
        self.state = state
        self.email = email
        self.services = services
        self.writeServices = writeServices
        self.reauthReason = reauthReason
    }

    enum CodingKeys: String, CodingKey {
        case state, email, services
        case writeServices = "write_services"
        case reauthReason = "reauth_reason"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawState = try container.decode(String.self, forKey: .state)
        guard let state = State(rawValue: rawState) else {
            throw DecodingError.dataCorruptedError(forKey: .state, in: container, debugDescription: "unknown state")
        }
        self.state = state
        let rawEmail = try container.decodeIfPresent(String.self, forKey: .email)?.trimmingCharacters(in: .whitespacesAndNewlines)
        email = rawEmail?.isEmpty == false ? rawEmail : nil
        services = Self.known(try container.decodeIfPresent([String].self, forKey: .services))
        writeServices = Self.known(try container.decodeIfPresent([String].self, forKey: .writeServices))
        reauthReason = try container.decodeIfPresent(String.self, forKey: .reauthReason).flatMap { raw in
            raw.isEmpty ? nil : (GoogleReauthReason(rawValue: raw) ?? .unknown)
        }
    }

    private static func known(_ raw: [String]?) -> [GoogleService] {
        let names = Set(raw ?? [])
        return GoogleService.allCases.filter { names.contains($0.rawValue) }
    }
}

public struct GoogleScopeSelection: Sendable, Equatable {
    public private(set) var read: Set<GoogleService>
    public private(set) var write: Set<GoogleService>

    public init() {
        read = Set(GoogleService.allCases)
        write = []
    }

    public init(granted status: GoogleWorkspaceStatus?) {
        let current = status.flatMap { known in
            (known.state == .signedIn || known.state == .reauthNeeded) && !known.services.isEmpty ? known : nil
        }
        let reads = current.map { Set($0.services) } ?? Set(GoogleService.allCases)
        read = reads
        write = Set((current?.writeServices ?? []).filter { $0.hasWriteOptIn && reads.contains($0) })
    }

    public var isEmpty: Bool { read.isEmpty }

    public func allowsWrite(_ service: GoogleService) -> Bool {
        service.hasWriteOptIn && read.contains(service)
    }

    public mutating func setRead(_ service: GoogleService, _ on: Bool) {
        if on {
            read.insert(service)
        } else {
            read.remove(service)
            write.remove(service)
        }
    }

    public mutating func setWrite(_ service: GoogleService, _ on: Bool) {
        if on, allowsWrite(service) { write.insert(service) } else { write.remove(service) }
    }

    public var startParams: [String: JSONValue] {
        [
            "services": .array(Self.names(read)),
            "write_services": .array(Self.names(write)),
        ]
    }

    private static func names(_ set: Set<GoogleService>) -> [JSONValue] {
        GoogleService.allCases.filter(set.contains).map { .string($0.rawValue) }
    }
}

public enum GoogleWorkspaceError: Error, Sendable, Equatable {
    case ownerOnly
    case notConfigured
    case invalidClient
    case notDesktopClient
    case invalidServices
    case unreachable
    case signInEnded
    case failed

    public var reason: String {
        switch self {
        case .ownerOnly: "Only the owner can manage Google Workspace sign-in."
        case .notConfigured: "Add your Google client first."
        case .invalidClient: "Google didn't accept that client ID and secret. Check them and try again."
        case .notDesktopClient: "That Google client isn't a Desktop app client. Create a Desktop app client and try again."
        case .invalidServices: "Choose at least one Google service."
        case .unreachable: "Couldn't reach Google. Check the connection and try again."
        case .signInEnded: "This sign-in has ended. Start again."
        case .failed: "Something went wrong with Google Workspace. Try again."
        }
    }

    static func from(_ error: any Error) -> GoogleWorkspaceError {
        if let known = error as? GoogleWorkspaceError { return known }
        guard let transport = error as? GatewayTransportError, case .rpc(let rpc) = transport else { return .failed }
        let code = rpc.data?["code"]?.stringValue
        switch (rpc.code, code) {
        case (4403, _): return .ownerOnly
        case (4101, "invalid_client"): return .invalidClient
        case (4101, "not_desktop_client"): return .notDesktopClient
        case (4101, "invalid_services"): return .invalidServices
        case (4101, "not_configured"): return .notConfigured
        case (5321, "unreachable"): return .unreachable
        default: return .failed
        }
    }
}

public enum GoogleWorkspaceCatalog {
    public static let appID = "google:workspace"
    public static let serviceID = appID
    public static let name = "Google Workspace"
    public static let summary = "Gmail, Calendar, Drive, Contacts, Sheets and Docs"
}

public enum GoogleWorkspaceCardState: Sendable, Equatable {
    case notConfigured
    case notSignedIn
    case signingIn
    case signedIn(email: String?, services: [GoogleService], writeServices: [GoogleService])
    case needsReauth(GoogleReauthReason)
    case failed(String)

    public static func resolve(
        status: GoogleWorkspaceStatus?, signingIn: Bool, failure: String?, authRequired: ServiceSignInReason? = nil
    ) -> GoogleWorkspaceCardState {
        if signingIn { return .signingIn }
        if let reason = failure?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty { return .failed(reason) }
        if let authRequired { return .needsReauth(GoogleReauthReason(signIn: authRequired)) }
        guard let status else { return .notSignedIn }
        switch status.state {
        case .notConfigured: return .notConfigured
        case .needsSignIn: return .notSignedIn
        case .signedIn: return .signedIn(email: status.email, services: status.services, writeServices: status.writeServices)
        case .reauthNeeded: return .needsReauth(status.reauthReason ?? .unknown)
        }
    }

    public var summary: String {
        switch self {
        case .notConfigured: "Not set up"
        case .notSignedIn: "Not signed in"
        case .signingIn: "Signing in…"
        case .signedIn(let email, _, _): email.map { "Signed in as \($0)" } ?? "Signed in"
        case .needsReauth(let reason): reason.plainReason
        case .failed(let reason): reason
        }
    }

    public var isSignedIn: Bool {
        if case .signedIn = self { return true }
        return false
    }
}

extension GoogleWorkspaceStatus {
    var catalogState: ConnectAppState {
        switch state {
        case .signedIn: .connected
        case .reauthNeeded: .needsAuthorization
        case .notConfigured, .needsSignIn: .disconnected
        }
    }
}

extension ConnectApp {
    public func applyingGoogleAuthRequired(_ reason: ServiceSignInReason?) -> ConnectApp {
        guard source == .googleWorkspace, let reason else { return self }
        var row = self
        row.state = .needsAuthorization
        row.authReason = GoogleReauthReason(signIn: reason).plainReason
        return row
    }
}
