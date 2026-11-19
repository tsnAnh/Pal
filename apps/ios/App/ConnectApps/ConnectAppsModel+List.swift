import Foundation
import PalBotProfile
import PalConnect
import PalDiagnostics

struct ConnectListEntry: Identifiable {
    let row: ConnectListRow
    let app: ConnectApp

    var id: String { row.id }
}

struct ConnectListSectionEntries: Identifiable {
    let section: ConnectListSection
    let entries: [ConnectListEntry]

    var id: String { section.id }

    var identifier: String {
        switch section.kind {
        case .needsAttention: "connectAppsSection-attention"
        case .connected: "connectAppsSection-connected"
        case .category(let name): "connectAppsSection-\(name)"
        }
    }
}

extension ConnectAppsModel {
    private var botInstall: ConnectBotInstall {
        if slack.needsReinstall { return .needsReinstall(summary: String(localized: "Needs reinstall for a new permission")) }
        if slack.installedCount > 0 { return .installed(summary: slack.summary) }
        return .notInstalled
    }

    func listRow(for listed: ConnectApp) -> ConnectListRow {
        let app = listed.applying(t3Reach: t3Reach)
        let bot = app.isBotApp ? botInstall : nil
        let state = ConnectRowState.resolve(ConnectRowInput(app: app, isBusy: busy.contains(app.id), bot: bot))
        var botSummary: String?
        switch bot {
        case .notInstalled: botSummary = String(localized: "Per bot · one-time setup")
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

    func matchedEntries() -> [ConnectListEntry] {
        let entries = cachedEntries()
        let needle = trimmedQuery
        return needle.isEmpty ? entries : entries.filter { ConnectCatalog.matches($0.app, needle: needle) }
    }

    var listSections: [ConnectListSectionEntries] {
        let perf = PalPerf.begin("connect.sections.main"); defer { perf.end() }
        let entries = matchedEntries()
        let byID = Dictionary(entries.map { ($0.row.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ConnectListLayout.sections(rows: entries.map(\.row), categories: catalog.categories).map { section in
            ConnectListSectionEntries(section: section, entries: section.rows.compactMap { byID[$0.id] })
        }
    }

    func performRowAction(_ app: ConnectApp, state: ConnectRowState) {
        guard state.actionTitle != nil else { return }
        if app.isT3Code, state != .connected {
            openT3Code()
        } else if case .custom = app.source {
            manage(app)
        } else if app.isBotApp {
            showsSlackPicker = true
        } else if app.oauthClientEntry != nil {
            oauthClientAction(app)
        } else if state == .connected, !app.requiresToken {
            manageAccounts(app)
        } else {
            Task { await connect(app) }
        }
    }

    func closeSlackPicker() {
        showsSlackPicker = false
        Task { await slack.load() }
    }
}
