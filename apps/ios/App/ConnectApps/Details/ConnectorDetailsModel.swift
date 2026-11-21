import Foundation
import Observation
import PalConnect
import PalProtocol

struct ConnectorAccountRow: Identifiable, Equatable {
    let name: String
    let state: ConnectorAccountState
    let reason: String?
    let isPending: Bool
    let canEdit: Bool

    var id: String { name }
}

@MainActor
@Observable
final class ConnectorDetailsModel {
    enum Load: Equatable {
        case loading
        case ready(ConnectorDetails?)
        case failed
    }

    struct Editing: Equatable {
        var draft: String
        var problem: String?
    }

    let appID: String
    private let parent: ConnectAppsModel
    private(set) var snapshot: ConnectApp
    private(set) var load: Load = .loading
    private(set) var policyBusy: Set<ConnectorToolGroup> = []
    private(set) var pendingAccount: String?
    private(set) var accountBusy: Set<String> = []
    var expanded: Set<ConnectorToolGroup> = []
    var showingAll: Set<ConnectorToolGroup> = []
    var renaming: [String: Editing] = [:]
    var adding: Editing?

    init(app: ConnectApp, parent: ConnectAppsModel) {
        appID = app.id
        snapshot = app
        self.parent = parent
    }

    var app: ConnectApp? {
        guard let live = parent.catalog.apps.first(where: { $0.id == appID }) else { return nil }
        return live.applying(t3Reach: parent.t3Reach)
    }

    var current: ConnectApp { app ?? snapshot }

    var slug: String? {
        if case .catalog(let entry) = current.source { entry.slug } else { nil }
    }

    var rowState: ConnectRowState { parent.listRow(for: current).state }

    var isConnected: Bool { current.state == .connected || current.state == .needsAuthorization }

    var details: ConnectorDetails? {
        if case .ready(let details) = load { details } else { nil }
    }

    var toolSections: [ConnectorToolSection] { details.map(ConnectorDetailsLayout.toolSections) ?? [] }

    var skills: [ConnectorSkill] { details?.skills ?? [] }

    var accounts: [ConnectorAccount] { current.accounts }

    var accountRows: [ConnectorAccountRow] {
        guard isConnected else { return [] }
        var rows = accounts.map { ConnectorAccountRow(name: $0.name, state: $0.state, reason: $0.reason, isPending: false, canEdit: supportsAccounts) }
        if rows.isEmpty {
            let state: ConnectorAccountState = current.state == .connected ? .connected : .needsReconnect
            rows = [ConnectorAccountRow(name: ConnectorAccountName.defaultName, state: state, reason: current.authReason, isPending: false, canEdit: false)]
        }
        if let pendingAccount, !rows.contains(where: { $0.name == pendingAccount }) {
            rows.append(ConnectorAccountRow(name: pendingAccount, state: .notConnected, reason: nil, isPending: true, canEdit: false))
        }
        return rows
    }

    var supportsAccounts: Bool { current.supportsAccounts }

    var isBusy: Bool { parent.busy.contains(appID) }

    var isSigningIn: Bool { parent.mcpSignIn != nil || isBusy }

    var firstAccountTarget: ConnectorAccountTarget? {
        current.supportsAccounts ? ConnectorAccountTarget.adding(ConnectorAccountName.defaultName, to: current) : nil
    }

    func refresh() async {
        guard let slug else {
            load = .ready(nil)
            return
        }
        if details == nil { load = .loading }
        if let live = app { snapshot = live }
        do {
            load = .ready(try await parent.service.details(slug: slug))
        } catch {
            load = .failed
        }
    }

    func reloadAll() async {
        await parent.reload()
        await refresh()
    }

    func retryApp() async {
        await parent.reload()
        if app != nil { await refresh() }
    }

    func toggle(_ group: ConnectorToolGroup) {
        if expanded.contains(group) { expanded.remove(group) } else { expanded.insert(group) }
    }

    func showAll(_ group: ConnectorToolGroup) {
        showingAll.insert(group)
    }

    func setPolicy(_ group: ConnectorToolGroup, to mode: ConnectorPolicyMode) async {
        guard let slug, !policyBusy.contains(group), case .ready(let held?) = load, held.policy.mode(for: group) != mode else { return }
        policyBusy.insert(group)
        defer { policyBusy.remove(group) }
        do {
            var updated = held
            updated.policy = try await parent.service.setPolicy(slug: slug, group: group, mode: mode)
            load = .ready(updated)
        } catch {
            parent.report(String(localized: "Couldn't change that setting. Try again."))
        }
    }

    func connect() {
        guard let target = app else { return }
        parent.performRowAction(target, state: rowState)
    }

    func disconnect() {
        parent.disconnectTarget = .app(current)
    }

    func beginAdd() {
        renaming = [:]
        adding = Editing(draft: "")
    }

    func cancelAdd() {
        adding = nil
    }

    func updateAdd(_ draft: String) {
        adding = Editing(draft: draft, problem: nil)
    }

    var addProblem: ConnectorAccountNameError? {
        guard let adding, !adding.draft.isEmpty else { return nil }
        return ConnectorAccountName.validate(adding.draft, existing: current.accountNames)
    }

    var canSubmitAdd: Bool {
        guard let adding else { return false }
        return !adding.draft.isEmpty && ConnectorAccountName.validate(adding.draft, existing: current.accountNames) == nil
    }

    func submitAdd() {
        guard canSubmitAdd, let name = adding?.draft, let app else { return }
        adding = nil
        pendingAccount = name
        Task {
            await parent.connect(app, account: ConnectorAccountTarget.adding(name, to: app))
            await finishSignIn()
        }
    }

    func signInAgain(_ name: String) {
        guard let app else { return }
        accountBusy.insert(name)
        Task {
            await parent.connect(app, account: app.supportsAccounts ? ConnectorAccountTarget.existing(name, in: app) : nil)
            await finishSignIn()
            accountBusy.remove(name)
        }
    }

    private func finishSignIn() async {
        while parent.mcpSignIn != nil { try? await Task.sleep(for: .milliseconds(300)) }
        await reloadAll()
        pendingAccount = nil
    }

    func remove(_ name: String) {
        guard let app else { return }
        if accountRows.count <= 1 || !app.supportsAccounts {
            disconnect()
            return
        }
        accountBusy.insert(name)
        Task {
            defer { accountBusy.remove(name) }
            do {
                try await parent.service.disconnect(app, account: name)
            } catch {
                parent.report(String(localized: "Couldn't remove that account. Try again."))
            }
            await reloadAll()
        }
    }

    func beginRename(_ name: String) {
        adding = nil
        renaming[name] = Editing(draft: name)
    }

    func cancelRename(_ name: String) {
        renaming[name] = nil
    }

    func updateRename(_ name: String, _ draft: String) {
        renaming[name] = Editing(draft: draft)
    }

    func renameProblem(_ name: String) -> ConnectorAccountNameError? {
        guard let editing = renaming[name], editing.draft != name else { return nil }
        return ConnectorAccountName.validate(editing.draft, existing: current.accountNames.filter { $0 != name })
    }

    func canSaveRename(_ name: String) -> Bool {
        guard let editing = renaming[name] else { return false }
        return editing.draft != name && renameProblem(name) == nil && !editing.draft.isEmpty
    }

    func saveRename(_ name: String) {
        guard canSaveRename(name), let draft = renaming[name]?.draft, let app else { return }
        accountBusy.insert(name)
        Task {
            defer { accountBusy.remove(name) }
            do {
                try await parent.service.renameAccount(app, from: name, to: draft)
                renaming[name] = nil
            } catch ConnectAppsError.accountName(let problem) {
                renaming[name]?.problem = problem.message
                return
            } catch {
                renaming[name]?.problem = String(localized: "Couldn't rename that account. Try again.")
                return
            }
            await reloadAll()
        }
    }
}
