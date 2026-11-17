import Foundation
import PalAuth
import PalConnect
import PalProtocol
import PalTransport

enum OAuthClientScript {
    static let argument = "-hermes-test-oauth-client"
    static let withoutPublicAddressArgument = "-hermes-test-oauth-client-no-public-address"
    static let asanaRedirect = "http://localhost:27890/callback"
    static let googleRedirect = "https://pal.example.test/webapp/google-install/callback"
    static let state = "scripted-state"
    static let session = "scripted-session"
    static let slackSession = "scripted-session-slack"
    static let loopbackAuthorize = [
        "asana": ("https://app.asana.com/-/oauth_authorize", OAuthClientScript.session),
        "slack": ("https://slack.com/oauth/v2_user/authorize", OAuthClientScript.slackSession),
    ]

    static var isActive: Bool { ProcessInfo.processInfo.arguments.contains(argument) }

    static func wrap(_ rpc: any ConnectRPC) -> any ConnectRPC {
        isActive ? ScriptedOAuthClientRPC(base: rpc, publicAddress: !ProcessInfo.processInfo.arguments.contains(withoutPublicAddressArgument)) : rpc
    }

    static func browser(_ real: any AuthorizationBrowser) -> any AuthorizationBrowser {
        isActive ? SystemBrowserAuthorization() : real
    }
}

actor ScriptedOAuthClientRPC: ConnectRPC {
    private struct Progress {
        var configured = false
        var connected = false
    }

    private static let googleNotes = "Google lets only the test users you added sign in until it verifies your app, and their sign-in lasts 7 days "
        + "while the app is in Testing. Publish and verify the app in Google Cloud Console to remove both limits."

    private let base: any ConnectRPC
    private let publicAddress: Bool
    private var progress: [String: Progress] = [
        "asana": Progress(), "google-workspace": Progress(), "github": Progress(), "slack": Progress(),
    ]
    private var items = 0
    private var vault: [String: String] = [:]

    init(base: any ConnectRPC, publicAddress: Bool) {
        self.base = base
        self.publicAddress = publicAddress
    }

    func call(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        let slug = params["slug"]?.stringValue ?? ""
        switch method {
        case "connectors.catalog": return try await catalog(params)
        case "connectors.oauth_client.setup": return try setup(slug)
        case "connectors.oauth_client.save": return try save(slug)
        case "connectors.oauth_client.connect": return try connect(slug)
        case "connectors.oauth_client.remove": return remove(slug)
        case "connectors.setup.check": return try check(slug, params)
        default: return try await auxiliary(method, params)
        }
    }

    private func auxiliary(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        switch method {
        case "vault.add": return addItem(params)
        case "vault.remove":
            vault[params["id"]?.stringValue ?? ""] = nil
            return ["ok": true]
        case "mcp.servers.add", "mcp.servers.update", "mcp.servers.test", "mcp.servers.remove":
            guard params["name"]?.stringValue == "github" else { return try await base.call(method, params) }
            return githubServer(method)
        case "mcp.servers.oauth.callback", "mcp.servers.oauth.cancel", "mcp.servers.oauth.poll":
            let session = params["session_id"]?.stringValue
            guard let slug = OAuthClientScript.loopbackAuthorize.first(where: { $0.value.1 == session })?.key else {
                return try await base.call(method, params)
            }
            return relay(method, slug: slug)
        default: return try await base.call(method, params)
        }
    }

    private func relay(_ method: String, slug: String) -> JSONValue {
        guard method == "mcp.servers.oauth.poll" else { return ["ok": true] }
        progress[slug]?.connected = true
        return ["status": "approved"]
    }

    private func status(_ slug: String) -> String {
        guard let current = progress[slug] else { return "needs_setup" }
        if current.connected { return "connected" }
        return current.configured || slug == "github" ? "not_connected" : "needs_setup"
    }

    private func githubServer(_ method: String) -> JSONValue {
        switch method {
        case "mcp.servers.add": progress["github"]?.connected = true
        case "mcp.servers.remove": progress["github"]?.connected = false
        default: break
        }
        return method == "mcp.servers.test" ? ["ok": true, "tools": [["name": "search_issues"]]] : ["ok": true]
    }

    private func check(_ slug: String, _ params: JSONValue) throws -> JSONValue {
        guard progress[slug] != nil else { throw Self.failure(4041, "CONNECTOR_NOT_FOUND") }
        let sent = params["values"]?.objectValue ?? [:]
        guard sent.values.allSatisfy({ vault[$0.stringValue ?? ""] != nil }) else { throw Self.failure(4000, "INVALID_PARAMS") }
        if !sent.values.contains(where: { vault[$0.stringValue ?? ""]?.contains("rejected") == true }) {
            return ["slug": .string(slug), "ok": true, "account": slug == "github" ? JSONValue.string("scripted-user") : JSONValue.null]
        }
        let reason = slug == "github" ? "INVALID_TOKEN" : "INVALID_CLIENT"
        return ["slug": .string(slug), "ok": false, "reason": .string(reason), "message": "The provider turned that down."]
    }

    private func catalog(_ params: JSONValue) async throws -> JSONValue {
        let live = try await base.call("connectors.catalog", params)
        let kept = (live["connectors"]?.arrayValue ?? []).filter { progress[$0["slug"]?.stringValue ?? ""] == nil }
        let asana: JSONValue = [
            "slug": "asana", "name": "Asana", "category": "Other", "icon": "plugin_glyph", "method": "oauth_client", "verified": true,
            "mcp_url": "https://mcp.asana.com/v2/mcp", "status": .string(status("asana")),
        ]
        return ["connectors": .array(kept + [asana, googleRow(), githubRow(), slackRow()])]
    }

    private func googleRow() -> JSONValue {
        let saved = progress["google-workspace"]?.configured == true
        let step = publicAddress ? (saved ? "client" : "console") : "address"
        return [
            "slug": "google-workspace", "name": "Google Workspace", "category": "Files and docs", "icon": "plugin_glyph",
            "method": "oauth_client", "verified": true, "status": .string(status("google-workspace")), "notes": .string(Self.googleNotes),
            "setup_guide": ScriptedSetupGuides.google,
            "setup_progress": ScriptedSetupGuides.progress(step, saved: saved ? ["client_id", "client_secret"] : []),
        ]
    }

    private func githubRow() -> JSONValue {
        let saved = progress["github"]?.connected == true
        return [
            "slug": "github", "name": "GitHub", "category": "Developer", "icon": "plugin_glyph", "method": "api_key", "verified": false,
            "mcp_url": "https://api.githubcopilot.com/mcp/", "status": .string(status("github")),
            "setup_guide": ScriptedSetupGuides.github,
            "setup_progress": ScriptedSetupGuides.progress(saved ? "token" : "token_page", saved: saved ? ["token"] : []),
        ]
    }

    private func slackRow() -> JSONValue {
        let saved = progress["slack"]?.configured == true
        return [
            "slug": "slack", "name": "Slack", "category": "Other", "icon": "plugin_glyph", "method": "oauth_client", "verified": true,
            "mcp_url": "https://mcp.slack.com/mcp", "status": .string(status("slack")),
            "setup_guide": ScriptedSetupGuides.slack,
            "setup_progress": ScriptedSetupGuides.progress(saved ? "client" : "app", saved: saved ? ["client_id", "client_secret"] : []),
        ]
    }

    private func setup(_ slug: String) throws -> JSONValue {
        guard let current = progress[slug] else { throw Self.failure(4041, "CONNECTOR_NOT_FOUND") }
        let loopback = OAuthClientScript.loopbackAuthorize[slug] != nil
        let consoles = ["asana": "https://app.asana.com/0/my-apps", "slack": "https://api.slack.com/apps"]
        let console = consoles[slug] ?? "https://console.cloud.google.com/apis/credentials"
        let redirect = loopback ? OAuthClientScript.asanaRedirect : (publicAddress ? OAuthClientScript.googleRedirect : nil)
        return [
            "slug": .string(slug), "configured": .bool(current.configured), "console_url": .string(console),
            "redirect_url": redirect.map(JSONValue.string) ?? JSONValue.null,
        ]
    }

    private func save(_ slug: String) throws -> JSONValue {
        guard progress[slug] != nil else { throw Self.failure(4041, "CONNECTOR_NOT_FOUND") }
        progress[slug]?.configured = true
        return try setup(slug)
    }

    private func connect(_ slug: String) throws -> JSONValue {
        guard let current = progress[slug], current.configured else { throw Self.failure(4090, "NEEDS_SETUP") }
        if let (authorize, session) = OAuthClientScript.loopbackAuthorize[slug] {
            let redirect = OAuthClientScript.asanaRedirect.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
            let link = "\(authorize)?response_type=code&state=\(OAuthClientScript.state)&redirect_uri=\(redirect)"
            return ["slug": .string(slug), "auth_url": .string(link), "session_id": .string(session)]
        }
        guard publicAddress else { throw Self.failure(4412, "NEEDS_PUBLIC_URL") }
        Task { await self.finishGoogleSignIn() }
        return [
            "slug": "google-workspace", "auth_url": .string("https://accounts.google.com/o/oauth2/v2/auth?state=\(OAuthClientScript.state)"),
            "session_id": .null,
        ]
    }

    private func finishGoogleSignIn() async {
        try? await Task.sleep(for: .milliseconds(1500))
        progress["google-workspace"]?.connected = true
    }

    private func remove(_ slug: String) -> JSONValue {
        progress[slug]?.connected = false
        return ["slug": .string(slug), "removed": true]
    }

    private func addItem(_ params: JSONValue) -> JSONValue {
        items += 1
        let id = "scripted-item-\(items)"
        vault[id] = params["secret"]?["api_key"]?.stringValue ?? ""
        return ["id": .string(id)]
    }

    private static func failure(_ code: Int, _ reason: String) -> GatewayTransportError {
        .rpc(RPCError(code: code, message: reason, data: ["reason": .string(reason)]))
    }
}
