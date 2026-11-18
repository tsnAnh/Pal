import Foundation
import PalConnect

extension ConnectAppsModel {
    func oauthClientAction(_ app: ConnectApp) {
        switch app.state {
        case .needsSetup, .disconnected, .needsAuthorization: presentOwnerSetup(app)
        case .connected: disconnectTarget = .app(app)
        }
    }

    func presentOwnerSetup(_ app: ConnectApp, failure: SetupStatus? = nil, startAtClient: Bool = false) {
        guard let entry = app.oauthClientEntry ?? app.setupGuideEntry, ownerSetup == nil else { return }
        ownerSetup = OwnerSetupModel(
            app: app, entry: entry, service: service, start: OwnerSetupStart(failure: failure, atClient: startAtClient)
        ) { [weak self] in self?.ownerSetup = nil }
    }
}
