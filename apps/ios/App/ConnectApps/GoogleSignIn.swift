import PalConnect
import PalDevice
import PalDiagnostics
import SwiftUI

@MainActor
private final class GoogleSessions {
    private(set) var current: GoogleSignInSession?

    func replace(_ session: GoogleSignInSession) async {
        let previous = current
        current = session
        await previous?.cancel()
    }

    func take() -> GoogleSignInSession? {
        defer { current = nil }
        return current
    }
}

@MainActor
enum GoogleSignIn {
    static func servicePasteRoute(connection: ConnectionModel) -> ServicePasteSignIn {
        let service = GoogleWorkspaceService(rpc: ConnectionRPC(model: connection), diagnostics: .osLog())
        let sessions = GoogleSessions()
        return ServicePasteSignIn(
            begin: { id in
                guard id == GoogleWorkspaceCatalog.serviceID else { return GoogleWorkspaceError.failed.reason }
                do {
                    let granted = try? await service.status()
                    let session = try await service.beginSignIn(GoogleScopeSelection(granted: granted))
                    guard ExternalLink.open(session.authURL) else {
                        await session.cancel()
                        return String(localized: "Couldn't open your browser.")
                    }
                    await sessions.replace(session)
                    return nil
                } catch {
                    return (error as? GoogleWorkspaceError ?? .failed).reason
                }
            },
            submit: { id, text in
                guard id == GoogleWorkspaceCatalog.serviceID, let session = sessions.current else {
                    return .failed(GoogleWorkspaceError.signInEnded.reason)
                }
                let outcome = await session.submit(text)
                if case .tryAgain = outcome {} else { _ = sessions.take() }
                return pasteOutcome(outcome)
            },
            cancel: { id in
                guard id == GoogleWorkspaceCatalog.serviceID else { return }
                await sessions.take()?.cancel()
            },
            reopen: { id in
                guard id == GoogleWorkspaceCatalog.serviceID, let url = sessions.current?.authURL else { return }
                ExternalLink.open(url)
            }
        )
    }

    static func pasteOutcome(_ outcome: GoogleSignInOutcome) -> ServicePasteOutcome {
        switch outcome {
        case .signedIn: .signedIn
        case .tryAgain(let note): .tryAgain(note)
        case .denied(let reason), .failed(let reason): .failed(reason)
        }
    }
}

private struct GoogleSignInReload: ViewModifier {
    let model: ConnectAppsModel

    @Environment(ServiceSignInCenter.self) private var signIn

    func body(content: Content) -> some View {
        content.onChange(of: signIn.lastResolution) { _, resolution in
            guard let resolution, resolution.service == GoogleWorkspaceCatalog.serviceID, resolution.outcome == .signedIn else { return }
            Task { await model.reload() }
        }
    }
}

extension View {
    func googleSignInReload(_ model: ConnectAppsModel) -> some View {
        modifier(GoogleSignInReload(model: model))
    }
}
