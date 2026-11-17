import Foundation
import PalConnect

extension ConnectAppsModel {
    func presentsSetupGuide(_ app: ConnectApp) -> Bool {
        guard app.oauthClientEntry == nil, app.setupGuideEntry != nil else { return false }
        presentSetupGuide(app)
        return true
    }

    func presentSetupGuide(_ app: ConnectApp, problem: OAuthClientProblem? = nil) {
        guard let entry = app.setupGuideEntry, let guide = entry.setupGuide else { return }
        setupGuideSheet = SetupGuideModel(
            app: app, entry: entry, guide: guide, service: service, problem: problem,
            connectAgain: { [weak self] in
                self?.setupGuideSheet = nil
                Task { await self?.continueGuidedSetup(app) }
            },
            finished: { [weak self] in await self?.continueGuidedSetup(app) }
        )
    }

    private func continueGuidedSetup(_ app: ConnectApp) async {
        setupGuideSheet = nil
        await reload()
        guard app.oauthClientEntry != nil else { return }
        await connectOAuthClient(catalog.apps.first { $0.id == app.id } ?? app)
    }
}
