import Foundation
import PalAuth
import PalDiagnostics
import PalProtocol
import PalREST
import Synchronization

public enum McpOAuthError: Error, Sendable, Equatable {
    case discoveryFailed
    case registrationFailed
    case browserUnavailable
    case cancelled
    case timedOut
    case listenerFailed
    case denied
    case stateMismatch
    case tokenExchangeFailed
    case randomnessUnavailable
    case rejectedByGateway(String?)
    case gatewayUnavailable
    case handshakeUsed
    case pasted(PasteError)

    public var reason: String {
        switch self {
        case .discoveryFailed: "We couldn't reach the sign-in service."
        case .registrationFailed: "The sign-in service didn't accept Pal."
        case .browserUnavailable: "We couldn't open your browser."
        case .cancelled: "Sign-in was cancelled."
        case .timedOut: "Sign-in took too long and was stopped."
        case .listenerFailed: "We couldn't wait for the sign-in to come back to this device."
        case .denied: "Access was not granted."
        case .stateMismatch: "The sign-in answer didn't match this request. Try again."
        case .tokenExchangeFailed: "The sign-in couldn't be completed. Try again."
        case .randomnessUnavailable: "This device couldn't prepare a secure sign-in."
        case .rejectedByGateway(let text): text ?? "Your Pal couldn't save the sign-in."
        case .gatewayUnavailable: "We couldn't reach your Pal to save the sign-in."
        case .handshakeUsed: "This sign-in was already used. Start again."
        case .pasted(let failure): failure.userText
        }
    }

    public static func from(_ error: any Error) -> McpOAuthError {
        if let known = error as? McpOAuthError { return known }
        if error is CancellationError { return .cancelled }
        if let paste = error as? PasteError { return .pasted(paste) }
        guard let signIn = error as? SignInError else { return .tokenExchangeFailed }
        switch signIn {
        case .cancelled: return .cancelled
        case .listenerTimedOut: return .timedOut
        case .listenerFailed: return .listenerFailed
        case .stateMismatch: return .stateMismatch
        case .authorizationDenied: return .denied
        case .browserUnavailable: return .browserUnavailable
        case .randomnessUnavailable: return .randomnessUnavailable
        default: return .tokenExchangeFailed
        }
    }
}

public enum McpOAuthScopes {
    public static func requested(resourceScopes: [String]?, serverScopes: [String]?) -> String? {
        let offered = [resourceScopes, serverScopes].compactMap { $0 }.first { !$0.isEmpty }
        guard let offered else { return nil }
        var seen = Set<String>()
        let unique = offered.filter { !$0.isEmpty && seen.insert($0).inserted }
        return unique.isEmpty ? nil : unique.joined(separator: " ")
    }
}

public struct McpOAuthGrant: Sendable, Equatable {
    public var clientID: String
    public var redirectURI: String
    public var tokenEndpoint: URL
    public var issuer: String
    public var accessToken: SecretString
    public var refreshToken: SecretString?
    public var expiresIn: Int?
    public var scope: String?
    public var tokenType: String?
}

struct McpOAuthServer: Sendable, Equatable {
    var resource: String
    var issuer: String
    var authorizationEndpoint: URL
    var tokenEndpoint: URL
    var registrationEndpoint: URL
    var scope: String?
}

struct McpOAuthHTTP: Sendable {
    let transport: any HTTPTransport

    func get(_ url: URL) async throws -> HTTPResult {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        return try await transport.send(request)
    }

    func post(_ url: URL, body: Data, contentType: String) async throws -> HTTPResult {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        return try await transport.send(request)
    }

    func json<T: Decodable>(_ type: T.Type, _ result: HTTPResult) -> T? {
        guard (200..<300).contains(result.response.statusCode) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(type, from: result.data)
    }
}

struct McpOAuthDiscovery: Sendable {
    let http: McpOAuthHTTP
    let diagnostics: Diagnostics

    private struct ResourceMetadata: Decodable {
        var resource: String?
        var authorizationServers: [String]?
        var scopesSupported: [String]?
    }

    private struct ServerMetadata: Decodable {
        var issuer: String?
        var authorizationEndpoint: String?
        var tokenEndpoint: String?
        var registrationEndpoint: String?
        var scopesSupported: [String]?
        var codeChallengeMethodsSupported: [String]?
    }

    func discover(resource: URL) async throws -> McpOAuthServer {
        guard Self.isSecure(resource), let host = resource.host(), !host.isEmpty else { throw McpOAuthError.discoveryFailed }
        let hint = await metadataHint(from: resource)
        var resourceMetadata: ResourceMetadata?
        for candidate in Self.resourceMetadataCandidates(for: resource, hint: hint) {
            guard let result = try? await http.get(candidate), let found = http.json(ResourceMetadata.self, result) else { continue }
            resourceMetadata = found
            break
        }
        let issuerText = resourceMetadata?.authorizationServers?.first { Self.url($0).map(Self.isSecure) ?? false }
            ?? Self.origin(of: resource)
        guard let issuerURL = Self.url(issuerText) else { throw McpOAuthError.discoveryFailed }
        for candidate in Self.serverMetadataCandidates(for: issuerURL) {
            guard let result = try? await http.get(candidate), let metadata = http.json(ServerMetadata.self, result),
                  let server = Self.server(from: metadata, issuer: issuerText, resource: resourceMetadata?.resource ?? resource.absoluteString, resourceScopes: resourceMetadata?.scopesSupported)
            else { continue }
            return server
        }
        diagnostics.warning("mcp-oauth", "authorization server metadata unavailable")
        throw McpOAuthError.discoveryFailed
    }

    private func metadataHint(from resource: URL) async -> URL? {
        guard let result = try? await http.get(resource), result.response.statusCode == 401,
              let header = result.response.value(forHTTPHeaderField: "WWW-Authenticate"),
              let hint = Self.resourceMetadataURL(inChallenge: header), Self.isSecure(hint), hint.host() == resource.host()
        else { return nil }
        return hint
    }

    private static func server(from metadata: ServerMetadata, issuer: String, resource: String, resourceScopes: [String]?) -> McpOAuthServer? {
        guard let metadataIssuer = metadata.issuer, normalized(metadataIssuer) == normalized(issuer),
              let authorization = metadata.authorizationEndpoint.flatMap(Self.url), isSecure(authorization),
              let token = metadata.tokenEndpoint.flatMap(Self.url), isSecure(token),
              let registration = metadata.registrationEndpoint.flatMap(Self.url), isSecure(registration)
        else { return nil }
        if let methods = metadata.codeChallengeMethodsSupported, !methods.contains("S256") { return nil }
        return McpOAuthServer(
            resource: resource, issuer: metadataIssuer, authorizationEndpoint: authorization, tokenEndpoint: token,
            registrationEndpoint: registration,
            scope: McpOAuthScopes.requested(resourceScopes: resourceScopes, serverScopes: metadata.scopesSupported)
        )
    }

    static func resourceMetadataURL(inChallenge header: String) -> URL? {
        guard let range = header.range(of: "resource_metadata=", options: .caseInsensitive) else { return nil }
        let rest = header[range.upperBound...]
        if rest.first == "\"" {
            let value = rest.dropFirst().prefix { $0 != "\"" }
            return Self.url(String(value))
        }
        return Self.url(String(rest.prefix { $0 != "," && $0 != " " }))
    }

    static func resourceMetadataCandidates(for resource: URL, hint: URL?) -> [URL] {
        var candidates = [URL]()
        if let hint { candidates.append(hint) }
        let base = Self.origin(of: resource)
        candidates.append(contentsOf: [base + "/.well-known/oauth-protected-resource"].compactMap(Self.url))
        let path = resource.path
        if !path.isEmpty, path != "/" {
            candidates.append(contentsOf: [base + "/.well-known/oauth-protected-resource" + path].compactMap(Self.url))
        }
        return candidates
    }

    static func serverMetadataCandidates(for issuer: URL) -> [URL] {
        let base = Self.origin(of: issuer)
        let path = issuer.path == "/" ? "" : issuer.path
        return [
            base + "/.well-known/oauth-authorization-server" + path,
            base + path + "/.well-known/openid-configuration",
        ].compactMap(Self.url)
    }

    static func origin(of url: URL) -> String {
        "\(url.scheme ?? "https")://\(url.host() ?? "")" + (url.port.map { ":\($0)" } ?? "")
    }

    private static func url(_ text: String) -> URL? {
        URL(string: text)
    }

    private static func normalized(_ issuer: String) -> String {
        issuer.hasSuffix("/") ? String(issuer.dropLast()) : issuer
    }

    private static func isSecure(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host()?.isEmpty == false
    }
}

public final class McpOAuthHandshake: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    struct Secrets: Sendable {
        let verifier: SecretString
        let state: SecretString
    }

    public let authorizeURL: URL
    public let redirectURI: String
    let redirectURL: URL
    let clientID: String
    let server: McpOAuthServer
    private let secrets: Mutex<Secrets?>

    init(authorizeURL: URL, redirectURI: String, redirectURL: URL, clientID: String, server: McpOAuthServer, secrets: Secrets) {
        self.authorizeURL = authorizeURL
        self.redirectURI = redirectURI
        self.redirectURL = redirectURL
        self.clientID = clientID
        self.server = server
        self.secrets = Mutex<Secrets?>(secrets)
    }

    public var isPending: Bool {
        return secrets.withLock { (value: inout Secrets?) -> Bool in
            return value != nil
        }
    }

    public var description: String { "<sign-in handshake>" }
    public var debugDescription: String { "<sign-in handshake>" }
    public var customMirror: Mirror { Mirror(self, children: []) }

    func peek() throws -> Secrets {
        let current = secrets.withLock { (value: inout Secrets?) -> Secrets? in
            return value
        }
        guard let current else { throw McpOAuthError.handshakeUsed }
        return current
    }

    func take() -> Secrets? {
        return secrets.withLock { (value: inout Secrets?) -> Secrets? in
            let taken = value
            value = nil
            return taken
        }
    }

    public func cancel() {
        secrets.withLock { (value: inout Secrets?) in
            value = nil
        }
    }
}

public struct McpOAuthFlow: Sendable {
    public static let clientName = "Pal"
    static let pasteRedirectPorts: ClosedRange<UInt16> = 49152...65535

    let http: McpOAuthHTTP
    let resource: URL
    let browser: any AuthorizationBrowser
    let callbackTimeout: Duration
    let diagnostics: Diagnostics

    public init(
        resource: URL,
        transport: any HTTPTransport,
        browser: any AuthorizationBrowser = UnavailableAuthorizationBrowser(),
        callbackTimeout: Duration = .seconds(300),
        diagnostics: Diagnostics = .silent
    ) {
        self.resource = resource
        http = McpOAuthHTTP(transport: transport)
        self.browser = browser
        self.callbackTimeout = callbackTimeout
        self.diagnostics = diagnostics
    }

    public func authorize() async throws -> McpOAuthGrant {
        let (pkce, state) = try Self.freshSecrets()
        let listener: LoopbackRedirectListener
        do {
            listener = try await LoopbackRedirectListener.start(timeout: callbackTimeout, expectedState: state, diagnostics: diagnostics)
        } catch {
            throw McpOAuthError.from(error)
        }
        defer { listener.cancel() }
        let handshake = try await begin(redirectURI: listener.redirectURI, pkce: pkce, state: state)
        let parameters: [String: String]
        do {
            parameters = try await Self.awaitCallback(listener: listener, browser: browser, url: handshake.authorizeURL)
        } catch {
            handshake.cancel()
            await browser.dismiss()
            throw McpOAuthError.from(error)
        }
        await browser.dismiss()
        return try await complete(handshake, parameters: parameters)
    }

    public func beginPasted() async throws -> McpOAuthHandshake {
        let (pkce, state) = try Self.freshSecrets()
        let port = UInt16.random(in: Self.pasteRedirectPorts)
        return try await begin(redirectURI: "http://127.0.0.1:\(port)\(LoopbackRedirectListener.callbackPath)", pkce: pkce, state: state)
    }

    public func complete(_ handshake: McpOAuthHandshake, parameters: [String: String]) async throws -> McpOAuthGrant {
        let secrets = try handshake.peek()
        let code: String
        do {
            code = try AuthorizationCallback.code(from: parameters, expectedState: secrets.state.reveal())
        } catch {
            handshake.cancel()
            throw McpOAuthError.from(error)
        }
        return try await exchange(handshake, code: code)
    }

    public func complete(_ handshake: McpOAuthHandshake, pasted text: String) async throws -> McpOAuthGrant {
        let secrets = try handshake.peek()
        switch PastedAuthorization.parse(text, expectedState: secrets.state.reveal(), expectedRedirect: handshake.redirectURL) {
        case .failure(let failure):
            if !failure.keepsAttemptOpen { handshake.cancel() }
            throw McpOAuthError.pasted(failure)
        case .success(let code):
            return try await exchange(handshake, code: code)
        }
    }

    private static func freshSecrets() throws -> (PKCE, String) {
        do {
            return (try PKCE.generate(), try PKCE.randomToken(byteCount: 24))
        } catch {
            throw McpOAuthError.randomnessUnavailable
        }
    }

    private func begin(redirectURI: String, pkce: PKCE, state: String) async throws -> McpOAuthHandshake {
        guard let redirectURL = URL(string: redirectURI) else { throw McpOAuthError.listenerFailed }
        let server = try await McpOAuthDiscovery(http: http, diagnostics: diagnostics).discover(resource: resource)
        let clientID = try await register(server: server, redirectURI: redirectURI)
        let authorizeURL = Self.authorizeURL(server: server, clientID: clientID, redirectURI: redirectURI, challenge: pkce.challenge, state: state)
        return McpOAuthHandshake(
            authorizeURL: authorizeURL, redirectURI: redirectURI, redirectURL: redirectURL, clientID: clientID, server: server,
            secrets: McpOAuthHandshake.Secrets(verifier: SecretString(pkce.verifier), state: SecretString(state))
        )
    }

    private func exchange(_ handshake: McpOAuthHandshake, code: String) async throws -> McpOAuthGrant {
        guard let secrets = handshake.take() else { throw McpOAuthError.handshakeUsed }
        return try await exchange(
            server: handshake.server, clientID: handshake.clientID, redirectURI: handshake.redirectURI,
            code: code, verifier: secrets.verifier.reveal()
        )
    }

    private struct Registration: Decodable {
        var clientId: String?
    }

    private func register(server: McpOAuthServer, redirectURI: String) async throws -> String {
        var body: [String: Any] = [
            "client_name": Self.clientName,
            "redirect_uris": [redirectURI],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
            "application_type": "native",
        ]
        if let scope = server.scope { body["scope"] = scope }
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else { throw McpOAuthError.registrationFailed }
        let result: HTTPResult
        do {
            result = try await http.post(server.registrationEndpoint, body: data, contentType: "application/json")
        } catch {
            throw McpOAuthError.registrationFailed
        }
        guard let registration = http.json(Registration.self, result), let clientID = registration.clientId, !clientID.isEmpty else {
            diagnostics.warning("mcp-oauth", "client registration refused")
            throw McpOAuthError.registrationFailed
        }
        return clientID
    }

    static func authorizeURL(server: McpOAuthServer, clientID: String, redirectURI: String, challenge: String, state: String) -> URL {
        var components = URLComponents(url: server.authorizationEndpoint, resolvingAgainstBaseURL: false) ?? URLComponents()
        var items = components.queryItems ?? []
        items += [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "resource", value: server.resource),
        ]
        if let scope = server.scope { items.append(URLQueryItem(name: "scope", value: scope)) }
        components.queryItems = items
        return components.url ?? server.authorizationEndpoint
    }

    private struct TokenResponse: Decodable {
        var accessToken: String?
        var tokenType: String?
        var refreshToken: String?
        var scope: String?
        var expiresIn: Int?

        enum CodingKeys: String, CodingKey {
            case accessToken, tokenType, refreshToken, scope, expiresIn
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            accessToken = try container.decodeIfPresent(String.self, forKey: .accessToken)
            tokenType = try container.decodeIfPresent(String.self, forKey: .tokenType)
            refreshToken = try container.decodeIfPresent(String.self, forKey: .refreshToken)
            scope = try container.decodeIfPresent(String.self, forKey: .scope)
            if let seconds = try? container.decodeIfPresent(Int.self, forKey: .expiresIn) {
                expiresIn = seconds
            } else if let text = try? container.decodeIfPresent(String.self, forKey: .expiresIn) {
                expiresIn = Int(text)
            }
        }
    }

    private func exchange(server: McpOAuthServer, clientID: String, redirectURI: String, code: String, verifier: String) async throws -> McpOAuthGrant {
        let form = Self.formBody([
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", redirectURI),
            ("client_id", clientID),
            ("code_verifier", verifier),
            ("resource", server.resource),
        ])
        let result: HTTPResult
        do {
            result = try await http.post(server.tokenEndpoint, body: form, contentType: "application/x-www-form-urlencoded")
        } catch {
            throw McpOAuthError.tokenExchangeFailed
        }
        guard let tokens = http.json(TokenResponse.self, result), let access = tokens.accessToken, !access.isEmpty,
              tokens.tokenType.map({ $0.lowercased() == "bearer" }) ?? true
        else {
            diagnostics.warning("mcp-oauth", "token exchange refused")
            throw McpOAuthError.tokenExchangeFailed
        }
        diagnostics.info("mcp-oauth", "authorization code exchanged")
        return McpOAuthGrant(
            clientID: clientID, redirectURI: redirectURI, tokenEndpoint: server.tokenEndpoint, issuer: server.issuer,
            accessToken: SecretString(access), refreshToken: tokens.refreshToken.flatMap { $0.isEmpty ? nil : SecretString($0) },
            expiresIn: tokens.expiresIn, scope: tokens.scope ?? server.scope, tokenType: tokens.tokenType
        )
    }

    static func formBody(_ pairs: [(String, String)]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = pairs.map { name, value in
            "\(name.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }
        return Data(encoded.joined(separator: "&").utf8)
    }

    private enum Step: Sendable {
        case callback([String: String])
        case browserEnded
    }

    private static func awaitCallback(listener: LoopbackRedirectListener, browser: any AuthorizationBrowser, url: URL) async throws -> [String: String] {
        try await withThrowingTaskGroup(of: Step.self) { group in
            group.addTask { .callback(try await listener.awaitCallback()) }
            group.addTask {
                try await browser.present(url)
                return .browserEnded
            }
            defer { group.cancelAll() }
            while let step = try await group.next() {
                switch step {
                case .callback(let parameters): return parameters
                case .browserEnded: throw SignInError.cancelled
                }
            }
            throw SignInError.cancelled
        }
    }
}
