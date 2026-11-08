import Foundation
import HermesAuth
import HermesConnect
import HermesDevice
import HermesDiagnostics
import HermesProtocol
import Observation
import UIKit

struct ConnectionRPC: ConnectRPC {
    let model: ConnectionModel

    func call(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        try await model.rpc(method, params)
    }
}

struct DeviceRow: Identifiable, Equatable {
    enum Action: Equatable {
        case allow
        case allowInSettings
        case connected
    }

    let id: DeviceConnectorID
    let title: String
    let subtitle: String
    let action: Action

    var renderID: String { "\(id.rawValue)-\(action)" }
}

struct ConnectNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct CredentialPrompt: Identifiable {
    let id = UUID()
    let app: ConnectApp
    let keys: [String]
}

enum ConnectDisconnectTarget: Identifiable {
    case app(ConnectApp)
    case device(DeviceRow)

    var id: String {
        switch self {
        case .app(let app): app.id
        case .device(let row): "device:\(row.id.rawValue)"
        }
    }

    var name: String {
        switch self {
        case .app(let app): app.name
        case .device(let row): row.title
        }
    }
}

enum ConnectChip {
    static let all = "all"
    static let iphone = "iphone"
}

@MainActor
@Observable
final class ConnectAppsModel {
    enum Phase: Equatable {
        case loading
        case ready
        case unavailable
    }

    enum Page {
        case catalog
        case yourPlugins
    }

    private(set) var phase: Phase = .loading
    private(set) var catalog = ConnectCatalog()
    private(set) var deviceRows: [DeviceRow] = []
    private(set) var busy: Set<String> = []
    var selection = ConnectChip.all
    var query = ""
    var page: Page = .catalog
    var notice: ConnectNotice?
    var credentialPrompt: CredentialPrompt?
    var disconnectTarget: ConnectDisconnectTarget?

    let botName: String
    private let profile: String?
    private let service: ConnectAppsService
    private let pool: DeviceHostPool
    private let permissions = SystemPermissions()
    private let diagnostics = Diagnostics.osLog()
    private var statuses: [DeviceConnectorStatus] = []
    private var localPermissions: [DeviceConnectorID: DeviceOSPermission] = [:]
    private var ledger: ConnectorLedger?
    private var observation: UUID?

    init(connection: ConnectionModel, pool: DeviceHostPool, profile: String?, botName: String, browser: any AuthorizationBrowser) {
        self.profile = profile
        self.botName = botName
        self.pool = pool
        service = ConnectAppsService(rpc: ConnectionRPC(model: connection), profile: profile, browser: browser, diagnostics: .osLog())
        rebuildDeviceRows()
    }

    var connectedCount: Int {
        catalog.connectedApps.count + deviceRows.filter { $0.action == .connected }.count
    }

    var connectedApps: [ConnectApp] { catalog.connectedApps }

    var connectedDeviceRows: [DeviceRow] { deviceRows.filter { $0.action == .connected } }

    var chips: [String] { [ConnectChip.all, ConnectChip.iphone] + catalog.categories }

    var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var searchedApps: [ConnectApp] { catalog.matching(trimmedQuery) }

    var searchedDevices: [DeviceRow] {
        let needle = trimmedQuery
        return deviceRows.filter { $0.title.localizedStandardContains(needle) || $0.subtitle.localizedStandardContains(needle) }
    }

    var searchedSkills: [InstalledSkill] { catalog.matchingSkills(trimmedQuery) }

    func start() async {
        await attachDevices()
        await reload()
    }

    func stop() async {
        if let observation, let ledger { await ledger.stopObserving(observation) }
        observation = nil
    }

    func reload() async {
        do {
            catalog = try await service.load()
            phase = .ready
        } catch {
            if catalog.apps.isEmpty { phase = .unavailable }
        }
    }

    func refreshPermissions() async {
        for id in DeviceConnectorID.allCases { localPermissions[id] = await permissions.status(of: id) }
        rebuildDeviceRows()
    }

    private func attachDevices() async {
        guard ledger == nil, let stack = await pool.stack(for: profile) else { return }
        ledger = stack.ledger
        let model = self
        observation = await stack.ledger.observe { snapshot in
            Task { @MainActor in model.apply(snapshot) }
        }
        await refreshPermissions()
        _ = try? await stack.ledger.refresh()
    }

    private func apply(_ snapshot: [DeviceConnectorStatus]) {
        statuses = snapshot
        rebuildDeviceRows()
        diagnostics.info("device", "ledger snapshot \(snapshot.count) connected=\(deviceRows.filter { $0.action == .connected }.count)")
    }

    private func rebuildDeviceRows() {
        deviceRows = DeviceConnectorID.allCases.map { id in
            let status = statuses.first { $0.id == id }
            let defaults = DeviceConnectorDefaults.entry(for: id)
            let local = localPermissions[id]
            let action: DeviceRow.Action
            if local == .denied || (local == nil && status?.osPermission == .denied && status?.state != .allowed) {
                action = .allowInSettings
            } else if status?.state == .allowed, local == nil || local == .granted {
                action = .connected
            } else {
                action = .allow
            }
            return DeviceRow(id: id, title: status?.title ?? defaults.title, subtitle: status?.subtitle ?? defaults.subtitle, action: action)
        }
    }

    func allow(_ row: DeviceRow) async {
        let key = "device:\(row.id.rawValue)"
        busy.insert(key)
        defer { busy.remove(key) }
        guard let ledger else { return report("Couldn't reach \(botName) right now. Try again in a moment.") }
        do {
            if !(await ledger.isLoaded) { _ = try await ledger.refresh() }
            var status = await permissions.status(of: row.id)
            if status == .notDetermined { status = await permissions.request(row.id) }
            diagnostics.info("device", "allow \(row.id.rawValue) os=\(status.rawValue)")
            localPermissions[row.id] = status
            switch status {
            case .granted:
                try await ledger.set(row.id, state: .allowed, osPermission: .granted)
                diagnostics.info("device", "set \(row.id.rawValue) ok")
                pool.remember(profile)
            case .denied, .notDetermined:
                try await ledger.set(row.id, osPermission: .denied)
            case .unsupported:
                report("\(row.title) isn't available on this iPhone.")
            }
        } catch {
            diagnostics.info("device", "allow \(row.id.rawValue) failed: \(Diagnostics.describe(error))")
            report("Couldn't turn on \(row.title). Try again.")
        }
        rebuildDeviceRows()
    }

    func turnOff(_ row: DeviceRow) async {
        guard let ledger else { return }
        do { try await ledger.set(row.id, state: .off) } catch { report("Couldn't turn off \(row.title). Try again.") }
        rebuildDeviceRows()
    }

    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    func connect(_ app: ConnectApp, credentials: [String: String] = [:]) async {
        busy.insert(app.id)
        defer { busy.remove(app.id) }
        do {
            try await service.connect(app, credentials: credentials)
        } catch let error as ConnectAppsError {
            handle(error, app: app)
        } catch {
            report("Couldn't connect \(app.name). Try again.")
        }
        await reload()
    }

    func disconnect(_ target: ConnectDisconnectTarget) async {
        switch target {
        case .device(let row):
            await turnOff(row)
        case .app(let app):
            busy.insert(app.id)
            defer { busy.remove(app.id) }
            do { try await service.disconnect(app) } catch { report("Couldn't disconnect \(app.name). Try again.") }
            await reload()
        }
    }

    private func handle(_ error: ConnectAppsError, app: ConnectApp) {
        switch error {
        case .cancelled: break
        case .credentialsRequired(let keys): credentialPrompt = CredentialPrompt(app: app, keys: keys)
        case .signInRequired: report("Connecting \(app.name) needs you to sign in to Nous Portal on your Hermes first.")
        case .unavailable, .failed: report("Couldn't connect \(app.name). Try again.")
        }
    }

    private func report(_ message: String) {
        notice = ConnectNotice(title: "Connect apps", message: message)
    }
}
