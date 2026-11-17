import Foundation
import PalAuth
import PalBotProfile
import PalClient
import PalConnect
import PalDesign
import PalDevice
import PalDiagnostics
import PalProtocol
import Observation

extension ConnectAppsModel {
    var isPastingAddress: Bool { pasteSession != nil }

    func beginPaste(_ app: ConnectApp) async {
        guard pasteSession == nil else { return }
        busy.insert(app.id)
        failures[app.id] = nil
        defer { busy.remove(app.id) }
        do {
            let session = try await service.beginUpworkPaste(app)
            guard ExternalLink.open(session.authorizeURL) else {
                await session.cancel()
                failures[app.id] = McpOAuthError.browserUnavailable.reason
                return
            }
            pasteSession = session
            pasteTargetID = app.id
            pasteState = .idle
        } catch let error as ConnectAppsError {
            handle(error, app: app)
        } catch {
            fail(app, "Couldn't connect \(app.name). Try again.")
        }
        await reload()
    }

    func submitPastedAddress(_ value: String) async {
        guard let session = pasteSession, pasteState.acceptsInput else { return }
        pasteState = .submitting
        switch await session.submit(value) {
        case .signedIn:
            pasteSession = nil
            pastingApp = nil
            pasteState = .idle
        case .tryAgain(let note):
            pasteState = .failure(note)
        case .failed(let reason):
            pasteSession = nil
            pastingApp = nil
            pasteState = .idle
            failures[pasteTargetID] = reason
        }
        await reload()
    }

    func reopenPasteSignIn() {
        if let url = pasteSession?.authorizeURL { ExternalLink.open(url) }
    }

    func cancelPaste() async {
        guard let session = pasteSession else { return }
        pasteSession = nil
        pastingApp = nil
        pasteState = .idle
        await session.cancel()
        await reload()
    }

    func beginOtherPaste(_ app: ConnectApp) async {
        guard pasteSession == nil else { return }
        do {
            let session = try await service.beginMcpPaste(app)
            guard ExternalLink.open(session.authorizeURL) else {
                await session.cancel()
                failures[app.id] = McpOAuthError.browserUnavailable.reason
                return
            }
            pasteSession = session
            pasteTargetID = app.id
            pasteState = .idle
            pastingApp = app
        } catch let error as ConnectAppsError {
            handle(error, app: app)
        } catch {
            fail(app, "Couldn't connect \(app.name). Try again.")
        }
    }
}
