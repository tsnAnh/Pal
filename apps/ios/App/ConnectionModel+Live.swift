import Foundation
import PalAuth
import PalDiagnostics
import PalClient
import PalREST
import PalTransport

extension ConnectionModel {
    static func live() -> ConnectionModel {
        let diagnostics = Diagnostics.osLog()
        let store = Self.credentialStore()
        if ProcessInfo.processInfo.arguments.contains("-hermes-reset-credentials") {
            try? store.clear()
        }
        let transport = URLSessionHTTPTransport()
        let identity = DeviceIdentity.resolve(
            store: KeychainDeviceIDStore(service: KeychainNamespace.qualified("\(keychainService).device")),
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
            auth = AuthSession(signedOutWith: transport, diagnostics: diagnostics, deviceID: identity.deviceID)
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

    private static let keychainService = Bundle.main.bundleIdentifier ?? "dev.tsnanh.hermes.bot"

    static func credentialStore() -> KeychainCredentialStore {
        KeychainCredentialStore(service: KeychainNamespace.qualified("\(keychainService).credentials"))
    }

    private static func keychainSession(
        store: KeychainCredentialStore,
        transport: any HTTPTransport,
        diagnostics: Diagnostics,
        deviceID: String
    ) -> AuthSession {
        (try? AuthSession(store: store, transport: transport, diagnostics: diagnostics, deviceID: deviceID))
            ?? AuthSession(signedOutWith: transport, diagnostics: diagnostics, deviceID: deviceID)
    }
}
