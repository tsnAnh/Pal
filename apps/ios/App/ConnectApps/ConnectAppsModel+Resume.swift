import PalConnect

extension ConnectAppsModel {
    var resumeOffer: SetupResumeOffer? {
        SetupResume.offer(records: setupRecords, apps: catalog.apps, on: .current)
    }

    func continueSetup(_ offer: SetupResumeOffer) {
        guard let app = catalog.apps.first(where: { $0.id == offer.appID }) else { return }
        if presentsDiscordFlow(app) { return }
        presentOwnerSetup(app)
    }
}
