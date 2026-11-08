import Foundation
import HermesAuth
import HermesChat
import HermesClient
import HermesDiagnostics
import HermesProtocol
import HermesREST
import HermesRFB
import HermesTransport
import Observation
import UIKit

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
    private(set) var phase: Phase = .signedOut
    private(set) var client: HermesClient?
    private(set) var userInitial = "H"

    private var auth: AuthSession
    private var keychainUnavailable: Bool
    private let transport: any HTTPTransport
    private let diagnostics: Diagnostics
    private let browser: WebAuthenticationBrowser
    let presence: ReachPresence
    private var connection: GatewayConnection?
    private var reopening: Task<GatewayConnection, any Error>?
    private var attentionChain: Task<Void, Never>?

    init(
        auth: AuthSession,
        transport: any HTTPTransport,
        diagnostics: Diagnostics,
        initialBaseURL: String,
        presence: ReachPresence,
        keychainUnavailable: Bool = false
    ) {
        self.auth = auth
        self.presence = presence
        self.keychainUnavailable = keychainUnavailable
        self.transport = transport
        self.diagnostics = diagnostics
        self.browser = WebAuthenticationBrowser()
        self.baseURLText = initialBaseURL
    }

    static func live() -> ConnectionModel {
        let diagnostics = Diagnostics.osLog()
        let store = KeychainCredentialStore()
        if ProcessInfo.processInfo.arguments.contains("-hermes-reset-credentials") {
            try? store.clear()
        }
        let transport = URLSessionHTTPTransport()
        let auth: AuthSession
        var keychainUnavailable = false
        do {
            auth = try AuthSession(store: store, transport: transport, diagnostics: diagnostics)
        } catch KeychainError.corruptItem {
            try? store.clear()
            auth = Self.keychainSession(store: store, transport: transport, diagnostics: diagnostics)
        } catch {
            diagnostics.info("auth", "credentials unavailable at launch: \(Diagnostics.describe(error))")
            keychainUnavailable = true
            auth = try! AuthSession(store: InMemoryCredentialStore(), transport: transport, diagnostics: diagnostics)
        }
        let identity = DeviceIdentity.resolve(
            store: KeychainDeviceIDStore(),
            formFactor: Self.formFactor(of: UIDevice.current.userInterfaceIdiom),
            appVersion: DeviceIdentity.appVersion(of: .main),
            diagnostics: diagnostics
        )
        return ConnectionModel(
            auth: auth,
            transport: transport,
            diagnostics: diagnostics,
            initialBaseURL: "",
            presence: ReachPresence(identity: identity, diagnostics: diagnostics),
            keychainUnavailable: keychainUnavailable
        )
    }

    private static func formFactor(of idiom: UIUserInterfaceIdiom) -> DeviceFormFactor {
        switch idiom {
        case .phone: .phone
        case .pad: .pad
        default: .other
        }
    }

    private static func keychainSession(store: KeychainCredentialStore, transport: any HTTPTransport, diagnostics: Diagnostics) -> AuthSession {
        (try? AuthSession(store: store, transport: transport, diagnostics: diagnostics))
            ?? (try! AuthSession(store: InMemoryCredentialStore(), transport: transport, diagnostics: diagnostics))
    }

    private func reloadKeychainCredentialsIfNeeded() {
        guard keychainUnavailable else { return }
        guard let reloaded = try? AuthSession(store: KeychainCredentialStore(), transport: transport, diagnostics: diagnostics) else { return }
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

    var isConnected: Bool {
        if case .connected = phase { true } else { false }
    }

    var isBusy: Bool {
        phase == .signingIn || phase == .connecting
    }

    func restore() async {
        reloadKeychainCredentialsIfNeeded()
        guard case .signedOut = phase, let baseURL = await auth.baseURL else { return }
        baseURLText = baseURL.displayString
        await connect()
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
        do {
            let credentials = try await NativeSignIn(transport: transport, diagnostics: diagnostics)
                .signIn(baseURL: baseURL, browser: browser)
            try await auth.adopt(credentials)
        } catch {
            phase = .failed(Self.message(for: error))
            return
        }
        await connect()
    }

    var chatConnector: HermesClientConnector? {
        client.map(HermesClientConnector.init(client:))
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
        guard let client else { throw HermesClientError.notSignedIn }
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
        guard path == Self.displayStreamPath, let baseURL = await auth.baseURL else { throw HermesClientError.notSignedIn }
        let url = baseURL.webSocketEndpoint(path, query: [URLQueryItem(name: "display_ticket", value: ticket)])
        return WebSocketRFBTransport(url: url, diagnostics: diagnostics)
    }

    func signOut() async {
        await connection?.close()
        connection = nil
        client = nil
        try? await auth.signOut()
        phase = .signedOut
    }

    private func connect() async {
        phase = .connecting
        let client = HermesClient(auth: auth, transport: transport, diagnostics: diagnostics, presence: presence)
        self.client = client
        do {
            await connection?.close()
            let connection = try await client.connect()
            self.connection = connection
            let description = try await client.describeRuntime(on: connection)
            if let userID = await auth.userID, let first = userID.first(where: \.isLetter) {
                userInitial = String(first).uppercased()
            }
            phase = .connected(instanceID: description.instanceID)
        } catch {
            phase = await auth.isSignedIn ? .failed(Self.message(for: error)) : .signedOut
        }
    }

    private static func message(for error: any Error) -> String {
        switch error {
        case let error as GatewayBaseURLError:
            switch error {
            case .insecureScheme: "Use an https address."
            case .empty: "Enter your Hermes address."
            default: "That address is not valid."
            }
        case let error as SignInError:
            switch error {
            case .cancelled: "Sign-in was cancelled."
            case .sessionExpired: "Your session expired. Sign in again."
            case .authorizationDenied: "Sign-in was declined."
            default: "Sign-in could not be completed."
            }
        case let error as GatewayTransportError:
            switch error {
            case .closed(.unauthorized), .handshakeRejected(401): "Your session expired. Sign in again."
            case .timedOut: "Hermes did not respond in time."
            default: "Could not connect to Hermes."
            }
        case is URLError:
            "Could not reach Hermes."
        default:
            "Something went wrong."
        }
    }
}
