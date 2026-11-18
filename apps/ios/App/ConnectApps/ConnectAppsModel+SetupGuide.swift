import Foundation
import PalConnect

extension ConnectAppsModel {
    func presentsSetupGuide(_ app: ConnectApp) -> Bool {
        guard let entry = app.setupGuideEntry else { return false }
        if entry.method == .botTokenStdio {
            presentSetupGuide(app)
        } else {
            presentOwnerSetup(app)
        }
        return true
    }

    func presentSetupGuide(_ app: ConnectApp) {
        guard let entry = app.setupGuideEntry, let guide = entry.setupGuide else { return }
        setupGuideSheet = SetupGuideModel(
            app: app, entry: entry, guide: guide, service: service
        ) { [weak self] in
            self?.setupGuideSheet = nil
            await self?.reload()
        }
    }
}
