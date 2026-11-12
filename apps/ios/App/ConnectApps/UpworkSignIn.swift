import PalConnect
import PalDevice
import PalDiagnostics
import PalREST

@MainActor
enum UpworkSignIn {
    static func native(connection: ConnectionModel) -> McpNativeSignIn? {
        #if os(macOS)
        McpNativeSignIn(
            flow: McpOAuthFlow(
                resource: UpworkConnector.serverURL,
                transport: URLSessionHTTPTransport(),
                browser: SystemBrowserAuthorization(),
                diagnostics: .osLog()
            ),
            rpc: ConnectionRPC(model: connection)
        )
        #else
        nil
        #endif
    }

    static func serviceHandler(connection: ConnectionModel) -> ServiceNativeSignIn? {
        guard let native = native(connection: connection) else { return nil }
        return { service in
            guard service == UpworkConnector.service else { return .failed(McpOAuthError.tokenExchangeFailed.reason) }
            do {
                try await native.run()
                return .signedIn
            } catch {
                let failure = McpOAuthError.from(error)
                return failure == .cancelled ? .cancelled : .failed(failure.reason)
            }
        }
    }
}
