import Foundation
import Observation
import PalAuth
import PalConnect
import PalDiagnostics
import PalProtocol
import PalREST

public protocol T3Authorizing: Sendable {
    func authorize(resource: URL) async throws -> McpOAuthGrant
}

public protocol T3Registering: Sendable {
    func register() async throws
    func unregister() async
}

public struct T3OAuthAuthorizer: T3Authorizing {
    private let browser: any AuthorizationBrowser
    private let transport: any HTTPTransport
    private let callbackTimeout: Duration
    private let diagnostics: Diagnostics

    public init(
        browser: any AuthorizationBrowser,
        transport: any HTTPTransport = URLSessionHTTPTransport(),
        callbackTimeout: Duration = .seconds(300),
        diagnostics: Diagnostics = .silent
    ) {
        self.browser = browser
        self.transport = transport
        self.callbackTimeout = callbackTimeout
        self.diagnostics = diagnostics
    }

    public func authorize(resource: URL) async throws -> McpOAuthGrant {
        try await McpOAuthFlow(
            resource: resource, transport: transport, browser: browser, callbackTimeout: callbackTimeout, diagnostics: diagnostics
        ).authorize()
    }
}

@MainActor
@Observable
public final class T3CodeController {
    public private(set) var status = T3CodeStatus()

    private let locator: T3Locator
    private let tokens: any T3TokenStore
    private let authorizer: any T3Authorizing
    private let registrar: any T3Registering
    private let bridge: T3McpBridge?
    private let pollInterval: Duration
    private let diagnostics: Diagnostics
    private var registeredPID: Int32?
    private var signInTask: Task<Void, Never>?
    private var rejectedToken: SecretString?

    public init(
        locator: T3Locator,
        tokens: any T3TokenStore,
        authorizer: any T3Authorizing,
        registrar: any T3Registering,
        bridge: T3McpBridge? = nil,
        pollInterval: Duration = .seconds(3),
        diagnostics: Diagnostics = .silent
    ) {
        self.locator = locator
        self.tokens = tokens
        self.authorizer = authorizer
        self.registrar = registrar
        self.bridge = bridge
        self.pollInterval = pollInterval
        self.diagnostics = diagnostics
    }

    public var connection: T3CodeConnection { status.connection }

    public func apply(_ event: T3CodeEvent) {
        status.apply(event)
    }

    public func watch() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: pollInterval)
        }
    }

    public func refresh() async {
        apply(.installationChecked(locator.installedApplication() != nil))
        let runtime = locator.runtime()
        if runtime != nil {
            apply(.runtimeSeen)
        } else {
            apply(.runtimeGone)
            registeredPID = nil
        }
        loadToken()
        guard let runtime, status.credential == .saved, status.attempt != .signingIn, registeredPID != runtime.pid else { return }
        await register(for: runtime)
    }

    public func connect() async {
        guard status.attempt != .signingIn, let runtime = locator.runtime() else { return }
        apply(.runtimeSeen)
        if status.credential == .saved {
            await register(for: runtime)
            return
        }
        apply(.signInStarted)
        let work = Task { await self.signIn(runtime) }
        signInTask = work
        await work.value
        signInTask = nil
    }

    private func signIn(_ runtime: T3Runtime) async {
        do {
            let grant = try await authorizer.authorize(resource: runtime.mcpURL)
            let expiresAt = grant.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }
            try tokens.save(T3Token(access: grant.accessToken, expiresAt: expiresAt))
        } catch is KeychainError {
            apply(.signInFailed(.storage))
            return
        } catch {
            let failure = McpOAuthError.from(error)
            apply(failure == .cancelled ? .signInCancelled : .signInFailed(.signIn(failure)))
            return
        }
        rejectedToken = nil
        apply(.signInSucceeded)
        await register(for: runtime)
    }

    public func cancelSignIn() {
        signInTask?.cancel()
    }

    public func disconnect() async {
        signInTask?.cancel()
        await registrar.unregister()
        do {
            try tokens.clear()
        } catch {
            diagnostics.warning("t3code", "token removal failed: \(Diagnostics.describe(error))")
            apply(.signInFailed(.storage))
            return
        }
        registeredPID = nil
        rejectedToken = nil
        apply(.disconnectTapped)
        await bridge?.closeAll()
    }

    public func unauthorized() {
        rejectedToken = (try? tokens.load())?.access
        apply(.unauthorized)
        registeredPID = nil
    }

    private func register(for runtime: T3Runtime) async {
        do {
            try await registrar.register()
            registeredPID = runtime.pid
            apply(.registrationSucceeded)
        } catch {
            diagnostics.info("t3code", "register failed: \(Diagnostics.describe(error))")
            apply(.registrationFailed)
        }
    }

    private func loadToken() {
        do {
            guard let token = try tokens.load() else {
                apply(.tokenMissing)
                return
            }
            if token.access == rejectedToken {
                apply(.unauthorized)
            } else {
                apply(.tokenFound(expired: token.isExpired()))
            }
        } catch {
            diagnostics.warning("t3code", "token read failed: \(Diagnostics.describe(error))")
            apply(.tokenMissing)
        }
    }
}
