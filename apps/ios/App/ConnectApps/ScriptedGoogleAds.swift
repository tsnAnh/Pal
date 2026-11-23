import PalProtocol
import PalTransport

struct ScriptedGoogleAds {
    static let slug = "google-ads"
    static let explorerArgument = "-hermes-test-google-ads-explorer"
    static let authorizeURL = "https://accounts.google.com/o/oauth2/v2/auth?state=scripted-google-ads"

    private var signedIn = false
    private var configured = false
    private var managerID: String?
    private var explorerPending: Bool

    init(explorerPending: Bool) {
        self.explorerPending = explorerPending
    }

    mutating func signIn() {
        signedIn = true
    }

    mutating func signOut() {
        signedIn = false
        configured = false
        managerID = nil
    }

    func connectReply() -> JSONValue {
        ["slug": .string(Self.slug), "auth_url": .string(Self.authorizeURL), "session_id": .null]
    }

    mutating func handle(_ method: String, _ params: JSONValue) throws -> JSONValue {
        switch method {
        case "connectors.google_ads.status":
            let state = signedIn ? "signed_in" : "needs_sign_in"
            return ["state": .string(state), "configured": .bool(configured), "login_customer_id": managerID.map(JSONValue.string) ?? .null]
        case "connectors.google_ads.save":
            guard signedIn else { throw Self.failure(4090, "NEEDS_SETUP") }
            let sent = params["login_customer_id"]?.stringValue
            if let sent, sent.isEmpty || !sent.allSatisfy({ $0.isASCII && $0.isWholeNumber }) { throw Self.failure(4000, "INVALID_PARAMS") }
            managerID = sent
            configured = true
            return ["tools": 6, "login_customer_id": sent.map(JSONValue.string) ?? .null]
        default:
            guard signedIn, configured else { throw Self.failure(4090, "NEEDS_SETUP") }
            if explorerPending {
                explorerPending = false
                return ["check": "explorer_access_needed", "accounts": .null]
            }
            return ["check": "ready", "accounts": 2]
        }
    }

    func row() -> JSONValue {
        let manager = managerID.map { "Manager account \($0)." } ?? ""
        let notes = ["Read only. Pal reads campaign stats and never changes a campaign.", manager].filter { !$0.isEmpty }.joined(separator: " ")
        return [
            "slug": .string(Self.slug), "name": "Google Ads", "category": "Monitoring and analytics", "icon": "google-ads",
            "method": "oauth_client", "verified": true, "status": .string(signedIn ? "connected" : "not_connected"),
            "notes": .string(notes), "setup_guide": .null, "setup_progress": .null,
        ]
    }

    private static func failure(_ code: Int, _ reason: String) -> GatewayTransportError {
        .rpc(RPCError(code: code, message: reason, data: ["reason": .string(reason)]))
    }
}
