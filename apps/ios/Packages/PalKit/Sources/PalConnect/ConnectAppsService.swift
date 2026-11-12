import Foundation
import PalAuth
import PalDiagnostics
import PalProtocol
import PalTransport

public protocol ConnectRPC: Sendable {
    func call(_ method: String, _ params: JSONValue) async throws -> JSONValue
}

public enum ConnectAppsError: Error, Sendable, Equatable {
    case signInRequired
    case unavailable
    case cancelled
    case credentialsRequired([String])
    case signInFailed(String)
    case failed
}

public struct ConnectAppsTiming: Sendable {
    public var pollInterval: Duration
    public var pollAttempts: Int

    public init(pollInterval: Duration = .seconds(1), pollAttempts: Int = 40) {
        self.pollInterval = pollInterval
        self.pollAttempts = pollAttempts
    }

    public static let standard = ConnectAppsTiming()
}

public struct ConnectAppsService: Sendable {
    let rpc: any ConnectRPC
    let profile: String?
    private let browser: any AuthorizationBrowser
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

    private static let account: JSONValue = ["type": "account"]

    func rawCall(_ method: String, _ params: [String: JSONValue] = [:]) async throws -> JSONValue {
        var scoped = params
        if let profile { scoped["profile"] = .string(profile) }
        return try await rpc.call(method, .object(scoped))
    }

    func call(_ method: String, _ params: [String: JSONValue] = [:]) async throws -> JSONValue {
        do {
            return try await rawCall(method, params)
        } catch let error as GatewayTransportError {
            throw Self.map(error)
        }
    }

    static func map(_ error: GatewayTransportError) -> ConnectAppsError {
        if case .rpc(let rpc) = error {
            let reason = rpc.data?["code"]?.stringValue ?? rpc.data?["reason"]?.stringValue ?? rpc.reasonCode
            if reason?.lowercased() == "needs_nous_auth" { return .signInRequired }
        }
        return .failed
    }

    public func load() async throws -> ConnectCatalog {
        async let hosted = attempt { try decodeList(await call("connectors.catalog"), key: "connectors", as: HostedConnectorEntry.self) }
        async let states = attempt {
            try decodeList(await call("connectors.list", ["owner": Self.account]), key: "connectors", as: HostedConnectorState.self)
        }
        async let presets = attempt { try decodeList(await call("mcp.catalog"), key: "servers", as: McpPresetEntry.self) }
        async let skills = attempt { InstalledSkill.parse(try await call("skills.manage", ["action": "list"])) }
        async let servers = attempt { try decodeList(await call("mcp.servers.list"), key: "servers", as: McpServerEntry.self) }
        let (hostedResult, statesResult, presetsResult, skillsResult, serversResult) = await (hosted, states, presets, skills, servers)
        if hostedResult == nil, presetsResult == nil { throw ConnectAppsError.unavailable }
        return ConnectCatalog.make(hosted: hostedResult ?? [], states: statesResult ?? [], mcp: presetsResult ?? [], skills: skillsResult ?? [], servers: serversResult ?? [])
    }

    private func attempt<T: Sendable>(_ work: () async throws -> T) async -> T? {
        do { return try await work() } catch {
            diagnostics.info("connect", "catalog read failed: \(Diagnostics.describe(error))")
            return nil
        }
    }

    private func decodeList<T: Decodable & Sendable>(_ value: JSONValue, key: String, as type: T.Type) throws -> [T] {
        guard let rows = value[key]?.arrayValue else { throw ConnectAppsError.failed }
        return rows.compactMap { try? $0.decoded(as: T.self) }
    }

    public func connect(_ app: ConnectApp, credentials: [String: String] = [:]) async throws {
        switch app.source {
        case .hosted(let slug): try await connectHosted(slug: slug, reconnect: app.state == .needsAuthorization)
        case .mcp where app.requiresAppSignIn: try await connectUpwork(app)
        case .mcp(let name, let requires): try await connectMcp(name: name, requires: requires, credentials: credentials)
        case .custom(let info):
            do { _ = try await testCustomConnector(name: info.name) } catch { throw ConnectAppsError.failed }
        }
    }

    public func disconnect(_ app: ConnectApp) async throws {
        switch app.source {
        case .hosted(let slug): try await disconnectHosted(slug: slug)
        case .mcp(let name, _): _ = try await call("mcp.servers.remove", ["name": .string(name)])
        case .custom(let info): _ = try await call("mcp.servers.remove", ["name": .string(info.name)])
        }
    }

    private struct Operation: Decodable {
        struct Target: Decodable {
            var state: String
            var connectURL: String?

            enum CodingKeys: String, CodingKey {
                case state
                case connectURL = "connect_url"
            }
        }

        var opID: String
        var settled: Bool
        var targets: [Target]

        enum CodingKeys: String, CodingKey {
            case opID = "op_id"
            case settled, targets
        }

        var allConnected: Bool { !targets.isEmpty && targets.allSatisfy { $0.state == "connected" } }
        var failed: Bool { targets.contains { ["failed", "expired"].contains($0.state) } }
    }

    private func connectHosted(slug: String, reconnect: Bool) async throws {
        let started = try await call("connectors.connect", ["owner": Self.account, "connectors": [.string(slug)], "reconnect": .bool(reconnect)])
        guard let operation = try? started.decoded(as: Operation.self) else { throw ConnectAppsError.failed }
        if operation.allConnected { return }
        if let link = operation.targets.compactMap(\.connectURL).first.flatMap(URL.init(string:)), link.scheme?.lowercased() == "https" {
            do { try await browser.present(link) } catch is CancellationError { throw ConnectAppsError.cancelled } catch { throw ConnectAppsError.failed }
        }
        let ids: [String: JSONValue] = ["owner": Self.account, "op_id": .string(operation.opID)]
        _ = try? await call("connectors.operation.wake", ids)
        for _ in 0..<timing.pollAttempts {
            let status = try await call("connectors.operation.status", ids)
            if let current = try? status.decoded(as: Operation.self) {
                if current.allConnected { return }
                if current.failed || current.settled { throw ConnectAppsError.failed }
            }
            try await Task.sleep(for: timing.pollInterval)
        }
        throw ConnectAppsError.failed
    }

    private func disconnectHosted(slug: String) async throws {
        let accounts = try await call("connectors.accounts", ["connector": .string(slug)])
        let ids = (accounts["accounts"]?.arrayValue ?? []).compactMap { $0["connection_id"]?.stringValue }
        guard !ids.isEmpty else { throw ConnectAppsError.failed }
        for id in ids { _ = try await call("connectors.accounts.remove", ["connection_id": .string(id)]) }
    }

    private func connectMcp(name: String, requires: [String], credentials: [String: String]) async throws {
        let missing = requires.filter { credentials[$0]?.isEmpty != false }
        guard missing.isEmpty else { throw ConnectAppsError.credentialsRequired(missing) }
        _ = try await call("mcp.servers.add", ["name": .string(name), "preset": .string(name)])
        do {
            if requires.isEmpty {
                try await authorizeMcp(name: name, browser: browser)
            } else {
                for key in requires {
                    _ = try await call("mcp.servers.set_api_key", ["name": .string(name), "value": .string(credentials[key] ?? ""), "env_var": .string(key)])
                }
            }
        } catch {
            _ = try? await call("mcp.servers.remove", ["name": .string(name)])
            throw error
        }
    }

    func authorizeMcp(name: String, browser: any AuthorizationBrowser, clientID: String? = nil) async throws {
        let listener = try await LoopbackRedirectListener.start(diagnostics: diagnostics)
        defer { listener.cancel() }
        var startParams: [String: JSONValue] = ["name": .string(name), "client_redirect_uri": .string(listener.redirectURI)]
        if let clientID { startParams["client_id"] = .string(clientID) }
        let started = try await call("mcp.servers.oauth.start", startParams)
        guard let flow = started["session_id"]?.stringValue, let link = started["auth_url"]?.stringValue.flatMap(URL.init(string:)),
              link.scheme?.lowercased() == "https" || link.scheme?.lowercased() == "http"
        else { throw ConnectAppsError.failed }
        let parameters: [String: String]
        do {
            parameters = try await Self.awaitRedirect(listener: listener, browser: browser, url: link)
        } catch {
            _ = try? await call("mcp.servers.oauth.cancel", ["name": .string(name), "session_id": .string(flow)])
            throw error is CancellationError || (error as? SignInError) == .cancelled ? ConnectAppsError.cancelled : ConnectAppsError.failed
        }
        var relay: [String: JSONValue] = ["name": .string(name), "session_id": .string(flow)]
        for key in ["code", "state", "error", "iss"] { if let value = parameters[key] { relay[key] = .string(value) } }
        _ = try await call("mcp.servers.oauth.callback", relay)
        for _ in 0..<timing.pollAttempts {
            let poll = try await call("mcp.servers.oauth.poll", ["name": .string(name), "session_id": .string(flow)])
            switch poll["status"]?.stringValue {
            case "approved": return
            case "error": throw ConnectAppsError.failed
            default: try await Task.sleep(for: timing.pollInterval)
            }
        }
        throw ConnectAppsError.failed
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
