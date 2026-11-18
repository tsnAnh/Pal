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
}
