import Foundation
import PalBotProfile
import PalConnect
import PalDiagnostics

struct ConnectListEntry: Identifiable {
    let row: ConnectListRow
    let app: ConnectApp

    var id: String { row.id }
}

extension ConnectAppsModel {
    func listRow(for listed: ConnectApp) -> ConnectListRow {
        let app = listed.applying(t3Reach: t3Reach)
        let bot = app.isBotApp ? botInstall : nil
        let state = ConnectRowState.resolve(ConnectRowInput(app: app, isBusy: busy.contains(app.id), bot: bot))
        var botSummary: String?
        switch bot {
        case .notInstalled: botSummary = String(localized: "Add \(botName) to Slack")
        case .installed(let summary): botSummary = summary
        case .needsReinstall, nil: break
        }
        return ConnectListRow(app: app, state: state, problem: failures[app.id], botSummary: botSummary)
    }

    var rowCacheKey: ConnectRowCache.Key {
        ConnectRowCache.Key(revision: catalogRevision, busy: busy, failures: failures, t3Reach: t3Reach, bot: botInstall)
    }

    func cachedEntries() -> [ConnectListEntry] {
        let key = rowCacheKey
        if let held = rowCache, held.key == key { return held.entries }
        rowBuilds += 1
        let entries = catalog.apps.map { ConnectListEntry(row: listRow(for: $0), app: $0) }
        rowCache = ConnectRowCache(key: key, entries: entries)
        return entries
    }

    func performRowAction(_ app: ConnectApp, state: ConnectRowState) {
        guard state.actionTitle != nil else { return }
        if app.isT3Code, state != .connected {
            openT3Code()
        } else if app.isShopify, state != .connected {
            openShopify()
        } else if case .custom = app.source {
            manage(app)
        } else if app.isBotApp {
            openSlack()
        } else if app.oauthClientEntry != nil {
            oauthClientAction(app)
        } else if state == .connected, !app.requiresToken {
            manageAccounts(app)
        } else {
            Task { await connect(app) }
        }
    }
}

enum ConnectorDetailsOrigin {
    case root
    case installed
}

extension ConnectAppsModel {
    var openDetailsRoute: ConnectorDetailsRoute? {
        navigation.screen == .installed ? installedDetails : rootDetails
    }

    func openDetails(_ app: ConnectApp) {
        guard app.opensDetails else { return }
        detailsModels[app.id] = nil
        let route = ConnectorDetailsRoute(appID: app.id)
        if navigation.screen == .installed { installedDetails = route } else { rootDetails = route }
    }

    func closeDetails() {
        if navigation.screen == .installed { installedDetails = nil } else { rootDetails = nil }
        releaseUnusedDetailsModels()
    }

    func releaseUnusedDetailsModels() {
        let open = Set([rootDetails, installedDetails].compactMap { $0?.appID })
        detailsModels = detailsModels.filter { open.contains($0.key) }
    }

    func detailsModel(appID: String) -> ConnectorDetailsModel? {
        if let held = detailsModels[appID] { return held }
        guard let app = catalog.apps.first(where: { $0.id == appID }) else { return nil }
        let created = ConnectorDetailsModel(app: app, parent: self)
        detailsModels[appID] = created
        return created
    }
}
