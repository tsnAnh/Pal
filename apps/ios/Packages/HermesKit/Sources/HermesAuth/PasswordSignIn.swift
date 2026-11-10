import Foundation
import HermesDiagnostics
import HermesREST

public enum SignInMethod: Sendable, Equatable {
    case browser
    case password(provider: String)
}

extension NativeSignIn {
    private struct ProviderList: Decodable, Sendable {
        struct Provider: Decodable, Sendable {
            var name: String
            var supportsPassword: Bool

            enum CodingKeys: String, CodingKey {
                case name
                case supportsPassword = "supports_password"
            }
        }

        var providers: [Provider]
    }

    public func discoverMethod(baseURL: GatewayBaseURL) async -> SignInMethod {
        let client = RESTClient(baseURL: baseURL, transport: transport, diagnostics: diagnostics)
        guard let list = try? await client.get("/api/auth/providers", as: ProviderList.self),
              list.providers.count == 1, let only = list.providers.first, only.supportsPassword, !only.name.isEmpty
        else { return .browser }
        return .password(provider: only.name)
    }

    public func signIn(
        baseURL: GatewayBaseURL,
        provider: String,
        username: String,
        password: String
    ) async throws -> StoredCredentials {
        let dedicated = URLSessionHTTPTransport(timeout: 20)
        let api = NativeAuthAPI(baseURL: baseURL, transport: dedicated, diagnostics: diagnostics, now: now, deviceID: deviceID)
        let flow = PasswordSignInFlow(api: api, transport: dedicated, baseURL: baseURL, diagnostics: diagnostics)
        let tokens = try await flow.run(provider: provider, username: username, password: password)
        diagnostics.info("signin", "password sign-in code exchanged")
        return StoredCredentials(baseURL: baseURL, tokens: tokens)
    }
}

struct PasswordSignInFlow: Sendable {
    let api: NativeAuthAPI
    let transport: any HTTPTransport
    let baseURL: GatewayBaseURL
    let diagnostics: Diagnostics

    private static let redirectURI = "http://127.0.0.1:1\(LoopbackRedirectListener.callbackPath)"

    private struct LoginBody: Encodable, Sendable {
        var provider: String
        var username: String
        var password: String
    }

    private struct LoginReply: Decodable, Sendable {
        var next: String
    }

    func run(provider: String, username: String, password: String) async throws -> TokenSet {
        let pkce = try PKCE.generate()
        let state = try PKCE.randomToken(byteCount: 24)
        let cookie = try await beginAuthorization(provider: provider, challenge: pkce.challenge, state: state)
        let next = try await submit(provider: provider, username: username, password: password, cookie: cookie)
        let code = try Self.authorizationCode(in: next, state: state)
        return try await api.exchange(code: code, verifier: pkce.verifier)
    }

    private func beginAuthorization(provider: String, challenge: String, state: String) async throws -> String {
        var request = URLRequest(url: api.authorizeURL(challenge: challenge, redirectURI: Self.redirectURI, state: state, provider: provider))
        request.httpMethod = "GET"
        let result = try await transport.send(request)
        let status = result.response.statusCode
        guard (300..<400).contains(status) else { throw Self.failure(status: status) }
        let cookies = Self.cookieHeader(from: result.response, for: baseURL.url)
        guard !cookies.isEmpty else { throw SignInError.rejected }
        return cookies
    }

    private func submit(provider: String, username: String, password: String, cookie: String) async throws -> String {
        var request = URLRequest(url: baseURL.endpoint("/auth/password-login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        do {
            request.httpBody = try JSONEncoder().encode(LoginBody(provider: provider, username: username, password: password))
        } catch {
            throw RESTError.encoding
        }
        let result = try await transport.send(request)
        guard result.response.statusCode == 200 else { throw Self.failure(status: result.response.statusCode) }
        guard let reply = try? JSONDecoder().decode(LoginReply.self, from: result.data) else { throw RESTError.decoding }
        return reply.next
    }

    static func authorizationCode(in next: String, state: String) throws -> String {
        guard let components = URLComponents(string: next),
              components.scheme == "http",
              components.host == "127.0.0.1",
              components.port == 1,
              components.path == LoopbackRedirectListener.callbackPath,
              components.user == nil, components.password == nil
        else { throw SignInError.rejected }
        var parameters: [String: String] = [:]
        for item in components.queryItems ?? [] {
            if let value = item.value, parameters[item.name] == nil { parameters[item.name] = value }
        }
        guard parameters["state"] == state else { throw SignInError.stateMismatch }
        guard let code = parameters["code"], !code.isEmpty else { throw SignInError.missingAuthorizationCode }
        return code
    }

    private static func failure(status: Int) -> SignInError {
        switch status {
        case 401: .invalidCredentials
        case 429: .rateLimited
        case 503: .serverUnavailable
        default: .rejected
        }
    }

    private static func cookieHeader(from response: HTTPURLResponse, for url: URL) -> String {
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { fields, pair in
            if let name = pair.key as? String, let value = pair.value as? String { fields[name] = value }
        }
        return HTTPCookie.cookies(withResponseHeaderFields: headers, for: url)
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }
}
