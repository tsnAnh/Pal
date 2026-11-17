import Foundation
import PalAuth
import PalDiagnostics
import PalProtocol
import PalTransport

public protocol ConnectRPC: Sendable {
    func call(_ method: String, _ params: JSONValue) async throws -> JSONValue
}

public enum ConnectAppsError: Error, Sendable, Equatable {
    case unavailable
    case cancelled
    case credentialsRequired([String])
    case signInFailed(String)
    case oauthClient(OAuthClientFailure, GatewayFault? = nil)
    case failed
    case faulted(GatewayFault)

    public var fault: GatewayFault? {
        switch self {
        case .faulted(let fault): fault
        case .oauthClient(_, let fault): fault
        default: nil
        }
    }

    public var oauthClientFailure: OAuthClientFailure? {
        if case .oauthClient(let failure, _) = self { return failure }
        return nil
    }
}

public struct ConnectAppsTiming: Sendable {
    public var pollInterval: Duration
    public var pollAttempts: Int
    public var consentAttempts: Int

    public init(pollInterval: Duration = .seconds(1), pollAttempts: Int = 40, consentAttempts: Int = 300) {
        self.pollInterval = pollInterval
        self.pollAttempts = pollAttempts
        self.consentAttempts = consentAttempts
    }

    public static let standard = ConnectAppsTiming()
}

public struct ConnectAppsService: Sendable {
    let rpc: any ConnectRPC
    let profile: String?
    let browser: any AuthorizationBrowser
    let systemBrowser: any AuthorizationBrowser
    let timing: ConnectAppsTiming
    let diagnostics: Diagnostics
    let nativeSignIn: McpNativeSignIn?

    public init(
        rpc: any ConnectRPC,
        profile: String?,
        browser: any AuthorizationBrowser,
        systemBrowser: any AuthorizationBrowser = UnavailableAuthorizationBrowser(),
        nativeSignIn: McpNativeSignIn? = nil,
        timing: ConnectAppsTiming = .standard,
        diagnostics: Diagnostics = .silent
    ) {
        self.nativeSignIn = nativeSignIn
        self.rpc = rpc
        self.profile = profile
        self.browser = browser
        self.systemBrowser = systemBrowser
        self.timing = timing
        self.diagnostics = diagnostics
    }

    public init(rpc: any ConnectRPC, profile: String?) {
        self.init(rpc: rpc, profile: profile, browser: UnavailableAuthorizationBrowser())
    }

    func rawCall(_ method: String, _ params: [String: JSONValue] = [:]) async throws -> JSONValue {
        var scoped = params
        if let profile { scoped["profile"] = .string(profile) }
        return try await rpc.call(method, .object(scoped))
    }

    func call(_ method: String, _ params: [String: JSONValue] = [:]) async throws -> JSONValue {
        do {
            return try await rawCall(method, params)
        } catch let error as GatewayTransportError {
            throw Self.map(error, method: method)
        }
    }

    static func map(_ error: GatewayTransportError, method: String? = nil) -> ConnectAppsError {
        if case .rpc(let rpc) = error, let method { return .faulted(GatewayFault(rpc, method: method)) }
        return .failed
    }

    public func load() async throws -> ConnectCatalog {
        async let entries = attempt { try decodeList(await call("connectors.catalog"), key: "connectors", as: PalCatalogEntry.self) }
        async let presets = attempt { try decodeList(await call("mcp.catalog"), key: "servers", as: McpPresetEntry.self) }
        async let skills = attempt { InstalledSkill.parse(try await call("skills.manage", ["action": "list"])) }
        async let servers = attempt { try decodeList(await call("mcp.servers.list"), key: "servers", as: McpServerEntry.self) }
        let (entriesResult, presetsResult, skillsResult, serversResult) = await (entries, presets, skills, servers)
        if entriesResult == nil, presetsResult == nil { throw ConnectAppsError.unavailable }
        return ConnectCatalog.make(
            catalog: entriesResult ?? [], mcp: presetsResult ?? [], skills: skillsResult ?? [], servers: serversResult ?? []
        )
    }

    public func legacyConnections() async throws -> LegacyConnectionsResult {
        let value = try await call("connectors.legacy")
        do { return try value.decoded(as: LegacyConnectionsResult.self) } catch { throw ConnectAppsError.failed }
    }

    private func attempt<T: Sendable>(_ work: () async throws -> T) async -> T? {
        do { return try await work() } catch {
            diagnostics.info("connect", "catalog read failed: \(Diagnostics.describe(error))")
            return nil
        }
    }

    func decodeList<T: Decodable & Sendable>(_ value: JSONValue, key: String, as type: T.Type) throws -> [T] {
        guard let rows = value[key]?.arrayValue else { throw ConnectAppsError.failed }
        return rows.compactMap { try? $0.decoded(as: T.self) }
    }

    public func connect(_ app: ConnectApp, credentials: [String: String] = [:]) async throws {
        switch app.source {
        case .catalog(let entry): try await connectCatalog(entry, credentials: credentials)
        case .mcp where app.requiresAppSignIn: try await connectUpwork(app)
        case .mcp(let name, let requires): try await connectMcp(name: name, requires: requires, credentials: credentials)
        case .custom(let info):
            do { _ = try await testCustomConnector(name: info.name) } catch { throw ConnectAppsError.failed }
        case .googleWorkspace: throw ConnectAppsError.unavailable
        }
    }

    public func disconnect(_ app: ConnectApp) async throws {
        switch app.source {
        case .catalog(let entry) where entry.method == .oauthClient: try await removeOAuthClientSignIn(slug: entry.slug)
        case .catalog(let entry): _ = try await call("mcp.servers.remove", ["name": .string(entry.slug)])
        case .mcp(let name, _): _ = try await call("mcp.servers.remove", ["name": .string(name)])
        case .custom(let info): _ = try await call("mcp.servers.remove", ["name": .string(info.name)])
        case .googleWorkspace:
            do { _ = try await GoogleWorkspaceService(rpc: rpc, diagnostics: diagnostics).signOut() } catch { throw ConnectAppsError.failed }
        }
    }

    private func connectCatalog(_ entry: PalCatalogEntry, credentials: [String: String]) async throws {
        switch entry.method {
        case .none: _ = try await addCatalogServer(entry)
        case .mcpOAuth:
            let added = try await addCatalogServer(entry)
            do {
                try await authorizeMcp(name: entry.slug, browser: browser)
            } catch {
                if added { _ = try? await call("mcp.servers.remove", ["name": .string(entry.slug)]) }
                throw error
            }
        case .apiKey:
            guard let token = credentials["token"], !token.isEmpty else { throw ConnectAppsError.credentialsRequired(["token"]) }
            try await storeCatalogToken(entry, token: token)
        case .native, .botApp, .unsupported: throw ConnectAppsError.unavailable
        case .oauthClient:
            if case .paste(let session) = try await connectOAuthClient(entry, route: .loopback) {
                await session.cancel()
                throw ConnectAppsError.unavailable
            }
        }
    }

    func addCatalogServer(_ entry: PalCatalogEntry, bearerToken: String? = nil) async throws -> Bool {
        guard let url = entry.mcpURL else { throw ConnectAppsError.failed }
        var params: [String: JSONValue] = ["name": .string(entry.slug), "config": ["url": .string(url.absoluteString), "transport": "http"]]
        if let bearerToken { params["bearer_token"] = .string(bearerToken) }
        do {
            _ = try await rawCall("mcp.servers.add", params)
            return true
        } catch let error as GatewayTransportError {
            guard case .rpc(let rpc) = error, rpc.code == 4090 else { throw ConnectAppsError.failed }
            return false
        }
    }

    private func storeCatalogToken(_ entry: PalCatalogEntry, token: String) async throws {
        if try await addCatalogServer(entry, bearerToken: token) { return }
        _ = try await call("mcp.servers.update", ["name": .string(entry.slug), "auth": "bearer", "bearer_token": .string(token)])
    }

    private func connectMcp(name: String, requires: [String], credentials: [String: String]) async throws {
        let missing = requires.filter { credentials[$0]?.isEmpty != false }
        guard missing.isEmpty else { throw ConnectAppsError.credentialsRequired(missing) }
        let alreadyAdded: Bool
        do {
            _ = try await rawCall("mcp.servers.add", ["name": .string(name), "preset": .string(name)])
            alreadyAdded = false
        } catch let error as GatewayTransportError {
            guard !requires.isEmpty, case .rpc(let rpc) = error, rpc.code == 4090 else { throw Self.map(error, method: "mcp.servers.add") }
            alreadyAdded = true
        }
        do {
            if requires.isEmpty {
                try await authorizeMcp(name: name, browser: browser)
            } else {
                for key in requires {
                    _ = try await call("mcp.servers.set_api_key", ["name": .string(name), "value": .string(credentials[key] ?? ""), "env_var": .string(key)])
                }
            }
        } catch {
            if !alreadyAdded { _ = try? await call("mcp.servers.remove", ["name": .string(name)]) }
            throw error
        }
    }

    public func tokenFailure(_ app: ConnectApp) async -> ConnectorFailure? {
        let name: String
        switch app.source {
        case .mcp(let preset, let requires) where !requires.isEmpty: name = preset
        case .catalog(let entry) where entry.method == .apiKey: name = entry.slug
        default: return nil
        }
        do { _ = try await testCustomConnector(name: name) } catch { return ConnectorFailure.from(error) }
        return nil
    }

    func startLoopback(port: UInt16? = nil, host: String = "127.0.0.1") async throws -> LoopbackRedirectListener {
        do {
            return try await LoopbackRedirectListener.start(fixedPort: port, redirectHost: host, diagnostics: diagnostics)
        } catch {
            throw ConnectAppsError.signInFailed(McpOAuthError.from(error).reason)
        }
    }

    func authorizeMcp(name: String, browser: any AuthorizationBrowser, clientID: String? = nil) async throws {
        if case .paste(let session) = try await signInMcp(name: name, platform: .mac, browser: browser, clientID: clientID, rollback: nil) {
            await session.cancel()
            throw ConnectAppsError.unavailable
        }
    }

    func completeLoopback(
        name: String, flow: String, link: URL, listener: LoopbackRedirectListener, browser: any AuthorizationBrowser
    ) async throws {
        let parameters: [String: String]
        do {
            parameters = try await Self.awaitRedirect(listener: listener, browser: browser, url: link)
        } catch {
            throw await failedSignIn(name: name, flow: flow, error: error)
        }
        try await relayCallback(name: name, flow: flow, parameters: parameters)
    }

    private enum Step: Sendable {
        case redirect([String: String])
        case browserClosed
    }

    private static func awaitRedirect(listener: LoopbackRedirectListener, browser: any AuthorizationBrowser, url: URL) async throws -> [String: String] {
        try await withThrowingTaskGroup(of: Step.self) { group in
            group.addTask { .redirect(try await listener.awaitCallback()) }
            group.addTask {
                try await browser.present(url)
                return .browserClosed
            }
            defer { group.cancelAll() }
            while let step = try await group.next() {
                switch step {
                case .redirect(let parameters):
                    await browser.dismiss()
                    return parameters
                case .browserClosed:
                    throw CancellationError()
                }
            }
            throw CancellationError()
        }
    }
}

public struct UnavailableAuthorizationBrowser: AuthorizationBrowser {
    public init() {}
    public func present(_ url: URL) async throws { throw SignInError.browserUnavailable }
    public func dismiss() async {}
}
