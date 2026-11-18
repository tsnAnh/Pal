import Foundation
import PalProtocol

public enum GoogleAdsConnector {
    public static let slug = "google-ads"
    public static let name = "Google Ads"
}

public enum GoogleAdsState: String, Sendable, Equatable {
    case needsSetup = "needs_setup"
    case needsSignIn = "needs_sign_in"
    case signedIn = "signed_in"
    case needsReconnect = "needs_reconnect"
}

public struct GoogleAdsStatus: Sendable, Equatable {
    public var state: GoogleAdsState
    public var configured: Bool
    public var loginCustomerID: String?

    public init(state: GoogleAdsState, configured: Bool, loginCustomerID: String? = nil) {
        self.state = state
        self.configured = configured
        self.loginCustomerID = loginCustomerID
    }
}

public enum GoogleAdsCheck: String, Sendable, Equatable {
    case ready
    case explorerAccessNeeded = "explorer_access_needed"
    case needsReauth = "needs_reauth"
    case unreachable
}

public struct GoogleAdsVerification: Sendable, Equatable {
    public var check: GoogleAdsCheck
    public var accounts: Int?

    public init(check: GoogleAdsCheck, accounts: Int? = nil) {
        self.check = check
        self.accounts = accounts
    }
}

public enum ManagerAccountID {
    public enum Parsed: Sendable, Equatable {
        case skip
        case id(String)
        case invalid
    }

    private static let separators: Set<Character> = ["-", "\u{2010}", "\u{2011}", "\u{2012}", "\u{2013}", "\u{2014}", "\u{2015}", "\u{2212}"]

    public static func parse(_ raw: String) -> Parsed {
        var digits = ""
        var sawDash = false
        for character in raw {
            if character.isASCII && character.isWholeNumber {
                digits.append(character)
            } else if separators.contains(character) {
                sawDash = true
            } else if !character.isWhitespace {
                return .invalid
            }
        }
        if !digits.isEmpty { return .id(digits) }
        return sawDash ? .invalid : .skip
    }
}

extension ConnectApp {
    public var isGoogleAds: Bool {
        if case .catalog(let entry) = source { entry.slug == GoogleAdsConnector.slug } else { false }
    }
}

extension ConnectAppsService {
    public func googleAdsStatus() async throws -> GoogleAdsStatus {
        let reply = try await oauthClientCall("connectors.google_ads.status", [:])
        guard let state = reply["state"]?.stringValue.flatMap(GoogleAdsState.init(rawValue:)),
              let configured = reply["configured"]?.boolValue
        else { throw ConnectAppsError.failed }
        let manager = reply["login_customer_id"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        return GoogleAdsStatus(state: state, configured: configured, loginCustomerID: manager)
    }

    @discardableResult
    public func saveGoogleAds(loginCustomerID: String?) async throws -> Int {
        let sent: JSONValue = loginCustomerID.map(JSONValue.string) ?? .null
        let reply = try await oauthClientCall("connectors.google_ads.save", ["login_customer_id": sent])
        return reply["tools"]?.intValue ?? 0
    }

    public func verifyGoogleAds() async throws -> GoogleAdsVerification {
        let reply = try await oauthClientCall("connectors.google_ads.verify", [:])
        guard let check = reply["check"]?.stringValue.flatMap(GoogleAdsCheck.init(rawValue:)) else { throw ConnectAppsError.failed }
        return GoogleAdsVerification(check: check, accounts: reply["accounts"]?.intValue)
    }

    public func signInGoogleAds() async throws {
        let started = try await startOAuthClient(GoogleAdsConnector.slug, redirect: nil)
        do {
            try await awaitOAuthClientConnected(slug: GoogleAdsConnector.slug, url: started.authURL, browser: systemBrowser)
        } catch ConnectAppsError.cancelled {
            throw CancellationError()
        }
    }
}
