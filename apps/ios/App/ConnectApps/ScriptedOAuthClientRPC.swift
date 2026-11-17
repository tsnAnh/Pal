import Foundation
import PalAuth
import PalConnect
import PalProtocol
import PalTransport

enum OAuthClientScript {
    static let argument = "-hermes-test-oauth-client"
    static let withoutPublicAddressArgument = "-hermes-test-oauth-client-no-public-address"
    static let loopbackRedirect = "http://localhost:27890/callback"
    static let googleRedirect = "https://pal.example.test/webapp/google-install/callback"
    static let mcpRedirect = "https://pal.example.test/webapp/mcp-oauth/callback"
    static let ipAddressArgument = "-hermes-test-oauth-client-ip-address"
    static let state = "scripted-state"
    static let addressSuggestion = "https://pal.example.test"
    static let offlineAddressHost = "offline.example.test"
    static let loopbackAuthorize = [
        "figma": ("https://www.figma.com/oauth", "scripted-session-figma"),
        "dropbox": ("https://www.dropbox.com/oauth2/authorize", "scripted-session-dropbox"),
        "canva": ("https://www.canva.com/api/oauth/authorize", "scripted-session-canva"),
    ]

    static var isActive: Bool { ProcessInfo.processInfo.arguments.contains(argument) }

    static func wrap(_ rpc: any ConnectRPC) -> any ConnectRPC {
        let arguments = ProcessInfo.processInfo.arguments
        return isActive
            ? ScriptedOAuthClientRPC(
                base: rpc, publicAddress: !arguments.contains(withoutPublicAddressArgument), ipAddress: arguments.contains(ipAddressArgument)
            ) : rpc
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
    private let ipAddress: Bool
    private var address: String?
    private var addressSaved = false
    private var progress: [String: Progress] = [
        "google-workspace": Progress(), "github": Progress(), "figma": Progress(),
        "dropbox": Progress(), "canva": Progress(), "discord": Progress(),
    ]
    private var discord = ScriptedDiscord()
    private var items = 0
    private var vault: [String: String] = [:]

    init(base: any ConnectRPC, publicAddress: Bool, ipAddress: Bool = false) {
        self.base = base
        address = publicAddress ? OAuthClientScript.addressSuggestion : nil
        self.ipAddress = ipAddress
    }

    func call(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        let slug = params["slug"]?.stringValue ?? ""
        switch method {
        case "connectors.catalog": return try await catalog(params)
        case "connectors.oauth_client.setup": return try setup(slug)
        case "connectors.oauth_client.save": return try save(slug)
        case "connectors.oauth_client.connect": return try connect(slug)
        case "connectors.oauth_client.remove": return remove(slug, removeClient: params["remove_client"]?.boolValue == true)
        case "connectors.setup.check": return try check(slug, params)
        case "webapp.public_url.get": return addressState()
        case "webapp.public_url.set": return try setAddress(params)
        case "webapp.public_url.check": return checkAddress()
        default: return try await auxiliary(method, params)
        }
    }

    private func auxiliary(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        switch method {
        case "vault.add": return addItem(params)
        case "connectors.discord.token", "connectors.discord.guilds", "connectors.discord.save":
            return try discord.handle(method, params, vault: vault)
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
            let accounts: [String: JSONValue] = ["github": "scripted-user", "discord": .string(ScriptedDiscord.botName)]
            return ["slug": .string(slug), "ok": true, "account": accounts[slug] ?? JSONValue.null]
        }
        let reason = slug == "github" || slug == "discord" ? "INVALID_TOKEN" : "INVALID_CLIENT"
        return ["slug": .string(slug), "ok": false, "reason": .string(reason), "message": "The provider turned that down."]
    }

    private func catalog(_ params: JSONValue) async throws -> JSONValue {
        let live = try await base.call("connectors.catalog", params)
        let kept = (live["connectors"]?.arrayValue ?? []).filter { progress[$0["slug"]?.stringValue ?? ""] == nil }
        let guided = ["figma", "dropbox", "canva"].map(mcpClientRow)
        return ["connectors": .array(kept + [googleRow(), githubRow(), discord.row()] + guided)]
    }

    private func googleRow() -> JSONValue {
        let saved = progress["google-workspace"]?.configured == true
        let step = address != nil && !ipAddress ? (saved ? "client" : "console") : "address"
        return [
            "slug": "google-workspace", "name": "Google Workspace", "category": "Docs and files", "icon": "plugin_glyph",
            "method": "oauth_client", "verified": true, "status": .string(status("google-workspace")), "notes": .string(Self.googleNotes),
            "setup_guide": ScriptedSetupGuides.google(addressProblem: ipAddress),
            "setup_progress": ScriptedSetupGuides.progress(step, saved: saved ? ["client_id", "client_secret"] : []),
        ]
    }

    private func githubRow() -> JSONValue {
        let saved = progress["github"]?.connected == true
        return [
            "slug": "github", "name": "GitHub", "category": "Developer tools", "icon": "plugin_glyph", "method": "api_key", "verified": false,
            "mcp_url": "https://api.githubcopilot.com/mcp/", "status": .string(status("github")),
            "setup_guide": ScriptedSetupGuides.github,
            "setup_progress": ScriptedSetupGuides.progress(saved ? "token" : "token_page", saved: saved ? ["token"] : []),
        ]
    }

    private func mcpClientRow(_ slug: String) -> JSONValue {
        let saved = progress[slug]?.configured == true
        let guides = [
            "figma": ("Figma", ScriptedSetupGuides.figma(publicAddress: address != nil)),
            "dropbox": ("Dropbox", ScriptedSetupGuides.dropbox(publicAddress: address != nil)),
            "canva": ("Canva", ScriptedSetupGuides.canva(publicAddress: address != nil)),
        ]
        let (name, guide) = guides[slug] ?? (slug, .null)
        let category = slug == "dropbox" ? "Docs and files" : "Design and web"
        return [
            "slug": .string(slug), "name": .string(name), "category": .string(category), "icon": "plugin_glyph",
            "method": "oauth_client", "verified": true, "mcp_url": .string("https://mcp.\(slug).com/mcp"), "status": .string(status(slug)),
            "setup_guide": guide,
            "setup_progress": ScriptedSetupGuides.progress(saved ? "client" : "app", saved: saved ? ["client_id", "client_secret"] : []),
        ]
    }

    private func setup(_ slug: String) throws -> JSONValue {
        guard let current = progress[slug] else { throw Self.failure(4041, "CONNECTOR_NOT_FOUND") }
        let loopback = OAuthClientScript.loopbackAuthorize[slug] != nil
        let consoles = [
            "figma": "https://www.figma.com/developers/apps", "dropbox": "https://www.dropbox.com/developers/console/apps",
            "canva": "https://www.canva.com/developers/apps",
        ]
        let console = consoles[slug] ?? "https://console.cloud.google.com/apis/credentials"
        let mcp = addressSaved ? address.map { "\($0)/webapp/mcp-oauth/callback" } : nil
        let redirect = loopback ? (mcp ?? OAuthClientScript.loopbackRedirect) : address.map { "\($0)/webapp/google-install/callback" }
        return [
            "slug": .string(slug), "configured": .bool(current.configured),
            "console_url": "https://console.cloud.google.com/apis/credentials",
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
            guard !addressSaved else { return gatewayConnect(slug) }
            let redirect = OAuthClientScript.loopbackRedirect.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
            let link = "\(authorize)?response_type=code&state=\(OAuthClientScript.state)&redirect_uri=\(redirect)"
            return ["slug": .string(slug), "auth_url": .string(link), "session_id": .string(session)]
        }
        guard address != nil else { throw Self.failure(4412, "NEEDS_PUBLIC_URL") }
        Task { await self.finishSignIn("google-workspace") }
        return [
            "slug": "google-workspace", "auth_url": .string("https://accounts.google.com/o/oauth2/v2/auth?state=\(OAuthClientScript.state)"),
        ]
    }

    private func gatewayConnect(_ slug: String) -> JSONValue {
        Task { await self.finishSignIn(slug) }
        let link = "\(OAuthClientScript.loopbackAuthorize[slug]?.0 ?? "")?state=\(OAuthClientScript.state)"
        return ["slug": .string(slug), "auth_url": .string(link), "session_id": .string("scripted-gateway-\(slug)")]
    }

    private func finishSignIn(_ slug: String) async {
        try? await Task.sleep(for: .milliseconds(1500))
        progress[slug]?.connected = true
    }

    private func addressState() -> JSONValue {
        [
            "url": address.map(JSONValue.string) ?? JSONValue.null, "routes_enabled": false,
            "suggestion": .string(OAuthClientScript.addressSuggestion),
        ]
    }

    private func setAddress(_ params: JSONValue) throws -> JSONValue {
        switch PublicAddress.evaluate(params["url"]?.stringValue ?? "") {
        case .clear: address = nil
        case .address(let url): address = url
        case .refused(let problem):
            throw GatewayTransportError.rpc(
                RPCError(code: 4000, message: "invalid_params", data: ["reason": "invalid_params", "field": "url", "problem": .string(problem.rawValue)])
            )
        }
        addressSaved = true
        return addressState()
    }

    private func checkAddress() -> JSONValue {
        guard let address else { return ["outcome": "no_address", "url": JSONValue.null] }
        let outcome = address.hasSuffix(OAuthClientScript.offlineAddressHost) ? "not_served" : "reachable"
        return ["outcome": .string(outcome), "url": .string(address)]
    }

    private func remove(_ slug: String, removeClient: Bool) -> JSONValue {
        progress[slug]?.connected = false
        if removeClient { progress[slug]?.configured = false }
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
