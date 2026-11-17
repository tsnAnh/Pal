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
    private var progress: [String: Progress] = ["asana": Progress(), "google-workspace": Progress()]
    private var items = 0

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
        case "vault.add": return addItem()
        case "vault.remove": return ["ok": true]
        case "mcp.servers.oauth.callback", "mcp.servers.oauth.cancel", "mcp.servers.oauth.poll":
            guard params["session_id"]?.stringValue == OAuthClientScript.session else { return try await base.call(method, params) }
            return relay(method)
        default: return try await base.call(method, params)
        }
    }

    private func relay(_ method: String) -> JSONValue {
        guard method == "mcp.servers.oauth.poll" else { return ["ok": true] }
        progress["asana"]?.connected = true
        return ["status": "approved"]
    }

    private func status(_ slug: String) -> String {
        guard let current = progress[slug] else { return "needs_setup" }
        if current.connected { return "connected" }
        return current.configured ? "not_connected" : "needs_setup"
    }

    private func catalog(_ params: JSONValue) async throws -> JSONValue {
        let live = try await base.call("connectors.catalog", params)
        let kept = (live["connectors"]?.arrayValue ?? []).filter { progress[$0["slug"]?.stringValue ?? ""] == nil }
        let asana: JSONValue = [
            "slug": "asana", "name": "Asana", "category": "Other", "icon": "plugin_glyph", "method": "oauth_client", "verified": true,
            "mcp_url": "https://mcp.asana.com/v2/mcp", "status": .string(status("asana")),
        ]
        let google: JSONValue = [
            "slug": "google-workspace", "name": "Google Workspace", "category": "Files and docs", "icon": "plugin_glyph",
            "method": "oauth_client", "verified": true, "status": .string(status("google-workspace")), "notes": .string(Self.googleNotes),
        ]
        return ["connectors": .array(kept + [asana, google])]
    }

    private func setup(_ slug: String) throws -> JSONValue {
        guard let current = progress[slug] else { throw Self.failure(4041, "CONNECTOR_NOT_FOUND") }
        let isAsana = slug == "asana"
        let console = isAsana ? "https://app.asana.com/0/my-apps" : "https://console.cloud.google.com/apis/credentials"
        let redirect = isAsana ? OAuthClientScript.asanaRedirect : (publicAddress ? OAuthClientScript.googleRedirect : nil)
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
        if slug == "asana" {
            let redirect = OAuthClientScript.asanaRedirect.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
            let link = "https://app.asana.com/-/oauth_authorize?response_type=code&state=\(OAuthClientScript.state)&redirect_uri=\(redirect)"
            return ["slug": "asana", "auth_url": .string(link), "session_id": .string(OAuthClientScript.session)]
        }
        guard publicAddress else { throw Self.failure(4412, "NEEDS_PUBLIC_URL") }
        Task { await self.finishGoogleSignIn() }
        return [
            "slug": "google-workspace", "auth_url": "https://accounts.google.com/o/oauth2/v2/auth?state=\(OAuthClientScript.state)",
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

    private func addItem() -> JSONValue {
        items += 1
        return ["id": .string("scripted-item-\(items)")]
    }

    private static func failure(_ code: Int, _ reason: String) -> GatewayTransportError {
        .rpc(RPCError(code: code, message: reason, data: ["reason": .string(reason)]))
    }
}
