import PalConnect
import PalDevice
import PalDiagnostics
import PalREST

@MainActor
private final class PasteSessions {
    private var sessions: [String: McpPasteSession] = [:]

    func replace(_ session: McpPasteSession, for service: String) async {
        await sessions.updateValue(session, forKey: service)?.cancel()
    }

    func session(for service: String) -> McpPasteSession? {
        return sessions[service]
    }

    func remove(_ service: String) -> McpPasteSession? {
        return sessions.removeValue(forKey: service)
    }
}

@MainActor
enum UpworkSignIn {
    static func native(connection: ConnectionModel) -> McpNativeSignIn {
        return McpNativeSignIn(
            flow: McpOAuthFlow(
                resource: UpworkConnector.serverURL,
                transport: URLSessionHTTPTransport(),
                browser: SystemBrowserAuthorization(),
                diagnostics: .osLog()
            ),
            rpc: ConnectionRPC(model: connection)
        )
    }

    static func serviceHandler(connection: ConnectionModel) -> ServiceNativeSignIn? {
        guard ConnectorPlatform.current.returnsAutomatically else { return nil }
        let native = native(connection: connection)
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

    static func servicePasteRoute(connection: ConnectionModel) -> ServicePasteSignIn {
        let native = native(connection: connection)
        let sessions = PasteSessions()
        return ServicePasteSignIn(
            begin: { service in
                guard service == UpworkConnector.service else { return McpOAuthError.tokenExchangeFailed.reason }
                do {
                    let session = try await native.beginPaste()
                    guard ExternalLink.open(session.authorizeURL) else {
                        await session.cancel()
                        return McpOAuthError.browserUnavailable.reason
                    }
                    await sessions.replace(session, for: service)
                    return nil
                } catch {
                    return McpOAuthError.from(error).reason
                }
            },
            submit: { service, text in
                guard let session = sessions.session(for: service) else { return .failed(McpOAuthError.handshakeUsed.reason) }
                switch await session.submit(text) {
                case .signedIn:
                    _ = sessions.remove(service)
                    return .signedIn
                case .tryAgain(let note):
                    return .tryAgain(note)
                case .failed(let reason):
                    _ = sessions.remove(service)
                    return .failed(reason)
                }
            },
            cancel: { service in
                await sessions.remove(service)?.cancel()
            },
            reopen: { service in
                if let url = sessions.session(for: service)?.authorizeURL { ExternalLink.open(url) }
            }
        )
    }
}
