import Foundation
import PalAuth
import PalProtocol
import PalTransport

public enum OAuthClientFailure: String, Sendable, Equatable, CaseIterable {
    case needsSetup = "NEEDS_SETUP"
    case needsPublicURL = "NEEDS_PUBLIC_URL"
    case invalidClient = "INVALID_CLIENT"
    case clientUnreadable = "CLIENT_UNREADABLE"
    case connectFailed = "CONNECT_FAILED"
    case notOwner = "NOT_OWNER"
    case saveFailed = "SAVE_FAILED"
    case unreachable = "UNREACHABLE"

    static let publicURLRPCCode = 4412

    public var reason: String {
        switch self {
        case .needsSetup: String(localized: "Set up this app on your Pal first.")
        case .needsPublicURL: String(localized: "Set this gateway's public address first.")
        case .invalidClient: String(localized: "That doesn't look like this app's client ID.")
        case .clientUnreadable: String(localized: "Couldn't read the saved client. Set it up again.")
        case .connectFailed: String(localized: "Couldn't start the sign-in. Try again.")
        case .notOwner: String(localized: "Only the owner can set up this app.")
        case .saveFailed: String(localized: "Couldn't save the client. Try again.")
        case .unreachable: String(localized: "Couldn't reach your Pal. Try again.")
        }
    }

    var discardsSavedItems: Bool {
        switch self {
        case .needsSetup, .invalidClient, .clientUnreadable, .notOwner: true
        case .needsPublicURL, .connectFailed, .saveFailed, .unreachable: false
        }
    }

    public static func classify(reason: String?, code: Int) -> OAuthClientFailure {
        if let known = reason.flatMap({ OAuthClientFailure(rawValue: $0.uppercased()) }) { return known }
        return code == publicURLRPCCode ? .needsPublicURL : .connectFailed
    }
}

public struct OAuthClientSetup: Sendable, Equatable {
    public var slug: String
    public var configured: Bool
    public var consoleURL: URL?
    public var redirectURL: String?

    public init(slug: String, configured: Bool, consoleURL: URL?, redirectURL: String?) {
        self.slug = slug
        self.configured = configured
        self.consoleURL = consoleURL
        self.redirectURL = redirectURL
    }

    init(_ value: JSONValue, slug: String) throws {
        guard let configured = value["configured"]?.boolValue else { throw ConnectAppsError.failed }
        self.init(
            slug: value["slug"]?.stringValue ?? slug, configured: configured,
            consoleURL: value["console_url"]?.stringValue.flatMap(URL.init(string:)).flatMap(Self.secure),
            redirectURL: value["redirect_url"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    private static func secure(_ url: URL) -> URL? {
        url.scheme?.lowercased() == "https" ? url : nil
    }
}

extension ConnectApp {
    public var oauthClientEntry: PalCatalogEntry? {
        if case .catalog(let entry) = source, entry.hasGuidedSetup { entry } else { nil }
    }

    public var isBotApp: Bool {
        if case .catalog(let entry) = source { entry.method == .botApp } else { false }
    }
}

extension ConnectAppsService {
    func oauthClientCall(_ method: String, _ params: [String: JSONValue]) async throws -> JSONValue {
        do {
            return try await rawCall(method, params)
        } catch let error as GatewayTransportError {
            guard case .rpc(let rpc) = error else { throw ConnectAppsError.oauthClient(.unreachable) }
            let failure = OAuthClientFailure.classify(reason: rpc.data?["reason"]?.stringValue, code: rpc.code)
            throw ConnectAppsError.oauthClient(failure, GatewayFault(rpc, method: method))
        }
    }

    public func oauthClientSetup(slug: String) async throws -> OAuthClientSetup {
        try OAuthClientSetup(try await oauthClientCall("connectors.oauth_client.setup", ["slug": .string(slug)]), slug: slug)
    }

    public func saveOAuthClient(_ entry: PalCatalogEntry, clientID: String, clientSecret: String) async throws -> OAuthClientSetup {
        let idItem = try await storeVaultSecret(label: String(localized: "\(entry.name) client ID"), value: clientID)
        let secretItem: String
        do {
            secretItem = try await storeVaultSecret(label: String(localized: "\(entry.name) client secret"), value: clientSecret)
        } catch {
            await discardVaultItems([idItem])
            throw error
        }
        do {
            let saved = try await oauthClientCall(
                "connectors.oauth_client.save",
                ["slug": .string(entry.slug), "client_id_item": .string(idItem), "client_secret_item": .string(secretItem)]
            )
            return try OAuthClientSetup(saved, slug: entry.slug)
        } catch {
            if let failure = (error as? ConnectAppsError)?.oauthClientFailure, failure.discardsSavedItems {
                await discardVaultItems([idItem, secretItem])
            }
            throw error
        }
    }

    private func storeVaultSecret(label: String, value: String) async throws -> String {
        let added: JSONValue
        do {
            added = try await rawCall("vault.add", ["kind": "api_key", "label": .string(label), "secret": .object(["api_key": .string(value)])])
        } catch let error as GatewayTransportError {
            if case .rpc = error { throw ConnectAppsError.oauthClient(.saveFailed) }
            throw ConnectAppsError.oauthClient(.unreachable)
        }
        guard let id = added["id"]?.stringValue, !id.isEmpty else { throw ConnectAppsError.oauthClient(.saveFailed) }
        return id
    }

    private func discardVaultItems(_ ids: [String]) async {
        for id in ids { _ = try? await rawCall("vault.remove", ["id": .string(id)]) }
    }

    public func removeOAuthClientSignIn(slug: String) async throws {
        _ = try await oauthClientCall("connectors.oauth_client.remove", ["slug": .string(slug)])
    }

    public func connectOAuthClient(_ entry: PalCatalogEntry) async throws {
        guard entry.status != .needsSetup else { throw ConnectAppsError.oauthClient(.needsSetup) }
        guard try await oauthClientSetup(slug: entry.slug).configured else { throw ConnectAppsError.oauthClient(.needsSetup) }
        let url = try await startOAuthClient(entry.slug)
        let undo = entry.status == .notConnected ? signInRollback(entry.slug) : nil
        do {
            try await awaitOAuthClientConnected(slug: entry.slug, url: url)
        } catch {
            await undo?()
            throw error
        }
    }

    private func signInRollback(_ slug: String) -> @Sendable () async -> Void {
        let service = self
        return { @Sendable in _ = try? await service.rawCall("connectors.oauth_client.remove", ["slug": .string(slug)]) }
    }

    private func startOAuthClient(_ slug: String) async throws -> URL {
        let result = try await oauthClientCall("connectors.oauth_client.connect", ["slug": .string(slug)])
        guard let url = result["auth_url"]?.stringValue.flatMap(URL.init(string:)),
              url.scheme?.lowercased() == "https" || url.scheme?.lowercased() == "http"
        else { throw ConnectAppsError.oauthClient(.connectFailed) }
        return url
    }

    private enum ConsentStep: Sendable {
        case connected
        case timedOut
        case browserReturned
    }

    private func awaitOAuthClientConnected(slug: String, url: URL) async throws {
        let browser = self.browser
        let outcome: ConsentStep
        do {
            outcome = try await withThrowingTaskGroup(of: ConsentStep.self, returning: ConsentStep.self) { group in
                group.addTask {
                    try await browser.present(url)
                    return .browserReturned
                }
                group.addTask { try await self.pollConnected(slug: slug, attempts: self.timing.consentAttempts) ? .connected : .timedOut }
                defer { group.cancelAll() }
                guard let first = try await group.next() else { return .timedOut }
                guard first == .browserReturned else { return first }
                return try await self.pollConnected(slug: slug, attempts: Self.returnedAttempts) ? .connected : .browserReturned
            }
        } catch {
            await browser.dismiss()
            if error is CancellationError || (error as? SignInError) == .cancelled { throw ConnectAppsError.cancelled }
            if case ConnectAppsError.failed = error { throw error }
            throw ConnectAppsError.signInFailed(McpOAuthError.from(error).reason)
        }
        await browser.dismiss()
        switch outcome {
        case .connected: return
        case .browserReturned: throw ConnectAppsError.cancelled
        case .timedOut: throw ConnectAppsError.signInFailed(McpSignInFailure.expired.reason)
        }
    }

    private static let returnedAttempts = 3

    private func pollConnected(slug: String, attempts: Int) async throws -> Bool {
        for attempt in 0..<attempts {
            if attempt > 0 { try await Task.sleep(for: timing.pollInterval) }
            let rows = try decodeList(await call("connectors.catalog"), key: "connectors", as: PalCatalogEntry.self)
            if rows.first(where: { $0.slug == slug })?.status == .connected { return true }
        }
        return false
    }
}
