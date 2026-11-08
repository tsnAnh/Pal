import Foundation
import HermesDiagnostics
import HermesREST

public protocol AuthorizationBrowser: Sendable {
    func present(_ url: URL) async throws
    func dismiss() async
}

public struct NativeSignIn: Sendable {
    private let transport: any HTTPTransport
    private let diagnostics: Diagnostics
    private let callbackTimeout: Duration
    private let now: @Sendable () -> Date
    private let deviceID: String?

    public init(
        transport: any HTTPTransport,
        diagnostics: Diagnostics = .silent,
        callbackTimeout: Duration = .seconds(300),
        deviceID: String? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.diagnostics = diagnostics
        self.callbackTimeout = callbackTimeout
        self.now = now
        self.deviceID = deviceID
    }

    private enum Step: Sendable {
        case callback([String: String])
        case browserEnded
    }

    public func signIn(baseURL: GatewayBaseURL, browser: any AuthorizationBrowser) async throws -> StoredCredentials {
        let api = NativeAuthAPI(baseURL: baseURL, transport: transport, diagnostics: diagnostics, now: now, deviceID: deviceID)
        let pkce = try PKCE.generate()
        let state = try PKCE.randomToken(byteCount: 24)
        let listener = try await LoopbackRedirectListener.start(timeout: callbackTimeout, diagnostics: diagnostics)
        let authorizeURL = api.authorizeURL(challenge: pkce.challenge, redirectURI: listener.redirectURI, state: state)
        diagnostics.info("signin", "presenting authorization to \(Diagnostics.describe(authorizeURL))")

        let parameters: [String: String]
        do {
            parameters = try await Self.awaitCallback(listener: listener, browser: browser, url: authorizeURL)
        } catch {
            listener.cancel()
            await browser.dismiss()
            throw error
        }
        listener.cancel()
        await browser.dismiss()

        if let denied = parameters["error"] {
            throw SignInError.authorizationDenied(String(denied.prefix(64)))
        }
        guard let returnedState = parameters["state"], returnedState == state else {
            diagnostics.warning("signin", "redirect state did not match")
            throw SignInError.stateMismatch
        }
        guard let code = parameters["code"], !code.isEmpty else { throw SignInError.missingAuthorizationCode }
        let tokens = try await api.exchange(code: code, verifier: pkce.verifier)
        diagnostics.info("signin", "authorization code exchanged")
        return StoredCredentials(baseURL: baseURL, tokens: tokens)
    }

    private static func awaitCallback(
        listener: LoopbackRedirectListener,
        browser: any AuthorizationBrowser,
        url: URL
    ) async throws -> [String: String] {
        try await withThrowingTaskGroup(of: Step.self) { group in
            group.addTask { .callback(try await listener.awaitCallback()) }
            group.addTask {
                try await browser.present(url)
                return .browserEnded
            }
            defer { group.cancelAll() }
            while let step = try await group.next() {
                switch step {
                case .callback(let parameters):
                    return parameters
                case .browserEnded:
                    throw SignInError.cancelled
                }
            }
            throw SignInError.cancelled
        }
    }
}
