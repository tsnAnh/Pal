import Foundation
import PalConnect
import PalDiagnostics
import PalProtocol
import Observation

@MainActor
@Observable
final class ConnectorAccountsModel: Identifiable {
    nonisolated var id: String { app.id }

    enum Phase: Equatable {
        case loading
        case ready
        case failed(String)
    }

    enum SaveState: Equatable {
        case idle
        case saving
        case saved(String)
        case failed(String)
    }

    let app: ConnectApp
    let botName: String
    private(set) var phase: Phase = .loading
    private(set) var accounts: [ConnectorAccount] = [] {
        didSet { remember() }
    }
    private(set) var policy = ConnectorPolicy.empty {
        didSet { remember() }
    }
    private(set) var tools: [HostedConnectorTool] = [] {
        didSet { remember() }
    }
    private(set) var toolsFailed = false
    private(set) var save: SaveState = .idle
    private(set) var busyAccount: String?
    var editing: String?
    var draft = ""
    var removal: ConnectorAccount?

    private let slug: String
    private let service: ConnectAppsService
    private let changed: () async -> Void
    private let diagnostics = Diagnostics.osLog()
    private let surfaces: SurfaceCache

    private struct Snapshot: Sendable {
        let accounts: [ConnectorAccount]
        let policy: ConnectorPolicy
        let tools: [HostedConnectorTool]
    }

    private var surfaceKey: SurfaceKey { .screen("connector-accounts-\(slug)", bot: botName) }

    init(
        app: ConnectApp, slug: String, botName: String, service: ConnectAppsService, surfaces: SurfaceCache,
        changed: @escaping () async -> Void
    ) {
        self.app = app
        self.slug = slug
        self.botName = botName
        self.service = service
        self.surfaces = surfaces
        self.changed = changed
        if let held = surfaces.remembered(Snapshot.self, .screen("connector-accounts-\(slug)", bot: botName)) {
            accounts = held.accounts
            policy = held.policy
            tools = held.tools
            phase = .ready
        }
    }

    private func remember() {
        surfaces.remember(Snapshot(accounts: accounts, policy: policy, tools: tools), surfaceKey)
    }

    var active: [ConnectorAccount] { accounts.filter { !$0.isRetired } }
    var retired: [ConnectorAccount] { accounts.filter(\.isRetired) }
    var enabled: Bool { policy.memberEnables(slug) }
    var lockedByOrganization: Bool { policy.orgLocks(slug) }
    var canEditPolicy: Bool { policy.revision != nil && !lockedByOrganization }
    var disabledTools: Set<String> { policy.memberDisabledTools(slug) }
    var lockedTools: Set<String> { policy.orgLockedTools(slug, among: tools) }

    func load() async {
        do {
            accounts = try await service.accounts(for: slug)
            phase = .ready
        } catch is CancellationError {
            return
        } catch {
            if phase != .ready { phase = .failed(Self.message(error, fallback: String(localized: "Couldn't load the accounts. Try again."))) }
            return
        }
        await loadPolicy()
    }

    private func loadPolicy() async {
        policy = (try? await service.connectorPolicy()) ?? .empty
        do {
            tools = try await service.connectorTools(for: slug)
            toolsFailed = false
        } catch {
            toolsFailed = tools.isEmpty
        }
    }

    func beginRename(_ account: ConnectorAccount) {
        editing = account.id
        draft = account.alias ?? ""
        save = .idle
    }

    func cancelRename() {
        editing = nil
        save = .idle
    }

    var draftProblem: String? {
        guard let editing else { return nil }
        let alias = draft.trimmingCharacters(in: .whitespaces)
        switch ConnectorAlias.problem(alias, among: accounts, renaming: editing) {
        case .invalid: return String(localized: "Use 1–32 lowercase letters, numbers or dashes, starting with a letter or number.")
        case .taken: return String(localized: "Another account already has that name.")
        case nil: return nil
        }
    }

    func submitRename() async {
        guard let id = editing, draftProblem == nil, let account = accounts.first(where: { $0.id == id }) else { return }
        let alias = draft.trimmingCharacters(in: .whitespaces)
        if alias == account.alias { return cancelRename() }
        busyAccount = id
        save = .saving
        defer { busyAccount = nil }
        do {
            let renamed = try await service.renameAccount(id, to: alias)
            if let index = accounts.firstIndex(where: { $0.id == id }) { accounts[index] = renamed }
            editing = nil
            save = .saved(String(localized: "Renamed to \(renamed.name)."))
        } catch {
            save = .failed(Self.message(error, fallback: String(localized: "Couldn't rename the account. The old name is kept.")))
        }
    }

    func confirmRemove() async {
        guard let account = removal else { return }
        removal = nil
        busyAccount = account.id
        save = .saving
        defer { busyAccount = nil }
        do {
            try await service.removeAccount(account.id)
            accounts.removeAll { $0.id == account.id }
            save = .saved(String(localized: "Removed \(account.name)."))
            await changed()
        } catch {
            save = .failed(Self.message(error, fallback: String(localized: "Couldn't remove the account. It is still connected.")))
        }
    }

    func setEnabled(_ on: Bool) async {
        await writePolicy(saved: on ? String(localized: "\(botName) can use \(app.name).") : String(localized: "\(botName) can't use \(app.name).")) {
            try await $0.setConnectorEnabled(self.slug, enabled: on, policy: self.policy)
        }
    }

    func setTool(_ tool: HostedConnectorTool, allowed: Bool) async {
        var off = disabledTools
        if allowed { off.remove(tool.slug) } else { off.insert(tool.slug) }
        await writePolicy(saved: String(localized: "Saved.")) {
            try await $0.setDisabledTools(self.slug, disabled: off, policy: self.policy)
        }
    }

    private func writePolicy(saved: String, _ write: (ConnectAppsService) async throws -> Void) async {
        save = .saving
        do {
            try await write(service)
            policy = try await service.connectorPolicy()
            save = .saved(saved)
        } catch {
            if let known = error as? ConnectorAccountsError, known == .policyChanged {
                policy = (try? await service.connectorPolicy()) ?? policy
            }
            save = .failed(Self.message(error, fallback: String(localized: "Couldn't save. The previous setting is kept.")))
        }
    }

    private static func message(_ error: Error, fallback: String) -> String {
        switch error as? ConnectorAccountsError {
        case .aliasTaken: String(localized: "Another account already has that name.")
        case .aliasInvalid: String(localized: "That name isn't valid.")
        case .notFound: String(localized: "That account no longer exists. Pull to refresh.")
        case .policyChanged: String(localized: "These settings changed elsewhere. The latest are shown; try again.")
        case .readOnly: String(localized: "You can't change these settings.")
        case .signInRequired: String(localized: "Sign in to Nous Portal on your Pal first.")
        default: fallback
        }
    }
}
