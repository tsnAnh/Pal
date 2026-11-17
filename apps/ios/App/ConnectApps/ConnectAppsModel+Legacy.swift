import PalConnect

extension ConnectAppsModel {
    func reconnect(_ row: LegacyReconnectRow) async {
        guard let appID = row.route.appID, let app = catalog.apps.first(where: { $0.id == appID }) else { return }
        switch row.route {
        case .connect:
            await connect(app)
        case .signIn:
            if app.source == .googleWorkspace { googleApp = app } else if app.requiresAppSignIn { upworkApp = app }
        case .needsSetup, .noDirectOption:
            break
        }
    }

    func retryLegacy() async {
        await legacy.load()
    }
}
