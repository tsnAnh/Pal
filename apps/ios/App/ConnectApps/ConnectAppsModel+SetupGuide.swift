import Foundation
import PalConnect

extension ConnectAppsModel {
    func presentsSetupGuide(_ app: ConnectApp) -> Bool {
        guard app.setupGuideEntry != nil else { return false }
        presentOwnerSetup(app)
        return true
    }
}
