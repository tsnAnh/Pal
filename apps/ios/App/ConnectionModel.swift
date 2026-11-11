import Foundation
import PalAuth
import PalChat
import PalClient
import PalDiagnostics
import PalProtocol
import PalREST
import PalRFB
import PalTransport
import Observation

@MainActor
@Observable
final class ConnectionModel {
    enum Phase: Equatable {
        case signedOut
        case signingIn
        case connecting
        case connected(instanceID: String)
        case failed(String)
    }

    var baseURLText: String
    var username = ""
    var password = ""
    private(set) var signInMethod: SignInMethod = .browser
    private(set) var phase: Phase = .signedOut
    private(set) var client: PalClient?
    private(set) var userInitial = "H"
    private(set) var userName = ""
    let localDeviceID: String?
    let cache: CacheStore

    private var auth: AuthSession
    private var keychainUnavailable: Bool
    private let transport: any HTTPTransport
    private let diagnostics: Diagnostics
    private let browser: WebAuthenticationBrowser
    let presence: ReachPresence
    private var connection: GatewayConnection?
    private var reopening: Task<GatewayConnection, any Error>?
    private var attentionChain: Task<Void, Never>?
    private var methodProbe: Task<Void, Never>?
    private var pendingRestore = false

    init(
        auth: AuthSession,
        transport: any HTTPTransport,
        diagnostics: Diagnostics,
        initialBaseURL: String,
        presence: ReachPresence,
        localDeviceID: String? = nil,
        keychainUnavailable: Bool = false,
        cache: CacheStore? = nil
    ) {
        self.localDeviceID = localDeviceID
        self.auth = auth
        self.presence = presence
        self.keychainUnavailable = keychainUnavailable
        self.transport = transport
        self.diagnostics = diagnostics
        self.browser = WebAuthenticationBrowser()
        self.baseURLText = initialBaseURL
        self.cache = cache ?? CacheStore.standard(diagnostics: diagnostics)
        if let identity = auth.restoredIdentity {
            baseURLText = identity.baseURL.displayString
            adopt(userName: identity.userID)
            pendingRestore = true
            phase = .connecting
            client = makeClient()
        }
    }

    private func adopt(userName userID: String?) {
        guard let userID, !userID.isEmpty else { return }
        userName = userID
        if let first = userID.first(where: \.isLetter) { userInitial = String(first).uppercased() }
    }

    static func live() -> ConnectionModel {
        let diagnostics = Diagnostics.osLog()
        let store = KeychainCredentialStore()
        if ProcessInfo.processInfo.arguments.contains("-hermes-reset-credentials") {
            try? store.clear()
        }
        let transport = URLSessionHTTPTransport()
        let identity = DeviceIdentity.resolve(
            store: KeychainDeviceIDStore(),
            formFactor: DeviceInfo.formFactor,
            appVersion: DeviceIdentity.appVersion(of: .main),
            model: DeviceInfo.hardwareIdentifier,
            os: DeviceInfo.osDescription,
            diagnostics: diagnostics
        )
        let auth: AuthSession
        var keychainUnavailable = false
        do {
            auth = try AuthSession(store: store, transport: transport, diagnostics: diagnostics, deviceID: identity.deviceID)
        } catch KeychainError.corruptItem {
            try? store.clear()
            auth = Self.keychainSession(store: store, transport: transport, diagnostics: diagnostics, deviceID: identity.deviceID)
        } catch {
            diagnostics.info("auth", "credentials unavailable at launch: \(Diagnostics.describe(error))")
            keychainUnavailable = true
            auth = try! AuthSession(store: InMemoryCredentialStore(), transport: transport, diagnostics: diagnostics, deviceID: identity.deviceID)
        }
        return ConnectionModel(
            auth: auth,
            transport: transport,
            diagnostics: diagnostics,
            initialBaseURL: "",
            presence: ReachPresence(identity: identity, diagnostics: diagnostics),
            localDeviceID: identity.deviceID,
            keychainUnavailable: keychainUnavailable
        )
    }

    private static func keychainSession(
        store: KeychainCredentialStore,
        transport: any HTTPTransport,
        diagnostics: Diagnostics,
        deviceID: String
    ) -> AuthSession {
        (try? AuthSession(store: store, transport: transport, diagnostics: diagnostics, deviceID: deviceID))
            ?? (try! AuthSession(store: InMemoryCredentialStore(), transport: transport, diagnostics: diagnostics, deviceID: deviceID))
    }

    private func reloadKeychainCredentialsIfNeeded() {
        guard keychainUnavailable else { return }
        guard let reloaded = try? AuthSession(store: KeychainCredentialStore(), transport: transport, diagnostics: diagnostics, deviceID: presence.deviceID) else { return }
        auth = reloaded
        keychainUnavailable = false
    }

    func report(attention: ReachAttention) {
        let presence = presence
        let previous = attentionChain
        attentionChain = Task {
            await previous?.value
            await presence.setAttention(attention)
        }
    }

    var accountKey: String { "\(baseURLText)|\(userName)" }

    var isConnected: Bool {
        if case .connected = phase { true } else { false }
    }

    var isBusy: Bool {
        phase == .signingIn || phase == .connecting
    }

    func restore() async {
        reloadKeychainCredentialsIfNeeded()
        let launching = pendingRestore
        guard launching || phase == .signedOut else { return }
        pendingRestore = false
        LaunchClock.mark("restore begin", on: diagnostics)
        guard let baseURL = await auth.baseURL else {
            if launching { phase = .signedOut }
            return
        }
        guard launching || phase == .signedOut else { return }
        baseURLText = baseURL.displayString
        await connect(reusingClient: launching)
    }

    func retryConnection() async {
        guard case .failed = phase else { return }
        await connect()
    }

    var usesPasswordSignIn: Bool {
        if case .password = signInMethod { true } else { false }
    }

    func addressChanged() {
        #if os(macOS)
        methodProbe?.cancel()
        signInMethod = .browser
        guard let baseURL = try? GatewayBaseURL(validating: baseURLText) else { return }
        let signIn = nativeSignIn
        methodProbe = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            let method = await signIn.discoverMethod(baseURL: baseURL)
            guard !Task.isCancelled else { return }
            signInMethod = method
        }
        #endif
    }

    private var nativeSignIn: NativeSignIn {
        NativeSignIn(transport: transport, diagnostics: diagnostics, deviceID: presence.deviceID)
    }

    func signIn() async {
        guard !isBusy else { return }
        let baseURL: GatewayBaseURL
        do {
            baseURL = try GatewayBaseURL(validating: baseURLText)
        } catch {
            phase = .failed(Self.message(for: error))
            return
        }
        phase = .signingIn
        #if os(macOS)
        await methodProbe?.value
        #endif
        do {
            let credentials: StoredCredentials
            if case .password(let provider) = signInMethod {
                let name = username.trimmingCharacters(in: .whitespacesAndNewlines)
                let secret = password
                password = ""
                guard !name.isEmpty, !secret.isEmpty else {
                    phase = .failed("Enter your username and password.")
                    return
                }
                credentials = try await nativeSignIn.signIn(baseURL: baseURL, provider: provider, username: name, password: secret)
            } else {
                credentials = try await nativeSignIn.signIn(baseURL: baseURL, browser: browser)
            }
            try await auth.adopt(credentials)
            baseURLText = baseURL.displayString
        } catch {
            phase = .failed(Self.message(for: error))
            return
        }
        password = ""
        await connect()
    }

    var chatConnector: PalClientConnector? {
        client.map(PalClientConnector.init(client:))
    }

    func rpc(_ method: String, _ params: JSONValue? = nil) async throws -> JSONValue {
        if let connection {
            do {
                return try await connection.call(method, params: params)
            } catch let error as GatewayTransportError {
                if case .rpc = error { throw error }
            } catch is CancellationError {
                throw CancellationError()
            } catch {}
        }
        let fresh = try await reopen()
        return try await fresh.call(method, params: params)
    }

    private func reopen() async throws -> GatewayConnection {
        if let reopening { return try await reopening.value }
        guard let client else { throw PalClientError.notSignedIn }
        let previous = connection
        let task = Task { try await client.connect() }
        reopening = task
        defer { reopening = nil }
        let fresh = try await task.value
        connection = fresh
        await previous?.close()
        return fresh
    }

    static let displayStreamPath = "/api/display/ws"

    func displayTransport(path: String, ticket: String) async throws -> any RFBTransport {
        guard path == Self.displayStreamPath, let baseURL = await auth.baseURL else { throw PalClientError.notSignedIn }
        let url = baseURL.webSocketEndpoint(path, query: [URLQueryItem(name: "display_ticket", value: ticket)])
        return WebSocketRFBTransport(url: url, diagnostics: diagnostics)
    }

    func signOut() async {
        await presence.unregisterPush()
        await connection?.close()
        connection = nil
        client = nil
        try? await auth.signOut()
        cache.removeAll()
        userName = ""
        userInitial = "H"
        phase = .signedOut
    }

    private func makeClient() -> PalClient {
        PalClient(auth: auth, transport: transport, diagnostics: diagnostics, presence: presence)
    }

    private func connect(reusingClient: Bool = false) async {
        phase = .connecting
        let client = reusingClient ? (self.client ?? makeClient()) : makeClient()
        self.client = client
        do {
            adopt(userName: await auth.userID)
            await connection?.close()
            let connection = try await client.connect()
            self.connection = connection
            let description = try await client.describeRuntime(on: connection)
            adopt(userName: await auth.userID)
            phase = .connected(instanceID: description.instanceID)
            cache.removeAll(except: accountKey)
            LaunchClock.mark("connected", on: diagnostics)
        } catch {
            if await auth.isSignedIn {
                phase = .failed(Self.message(for: error))
            } else {
                cache.removeAll()
                phase = .signedOut
            }
        }
    }

    private static func message(for error: any Error) -> String {
        switch error {
        case let error as GatewayBaseURLError:
            switch error {
            case .insecureScheme: "Use an https address."
            case .empty: "Enter your Pal address."
            default: "That address is not valid."
            }
        case let error as SignInError:
            switch error {
            case .cancelled: "Sign-in was cancelled."
            case .sessionExpired: "Your session expired. Sign in again."
            case .authorizationDenied: "Sign-in was declined."
            case .invalidCredentials: "Wrong username or password."
            case .rateLimited: "Too many attempts. Try again in a moment."
            case .serverUnavailable: "Pal is unavailable right now. Try again shortly."
            default: "Sign-in could not be completed."
            }
        case let error as GatewayTransportError:
            switch error {
            case .closed(.unauthorized), .handshakeRejected(401): "Your session expired. Sign in again."
            case .timedOut: "Pal did not respond in time."
            default: "Could not connect to Pal."
            }
        case is URLError:
            "Could not reach Pal."
        default:
            "Something went wrong."
        }
    }
}
