import Foundation
import HermesAuth
import HermesBotProfile
import HermesConnect
import HermesDesign
import HermesDevice
import HermesDiagnostics
import HermesProtocol
import Observation

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
    let warning: String?

    var isSwitch: Bool { warning != nil }

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

struct CapabilityKeyRequest: Identifiable, Equatable {
    let capability: String
    let keyName: String
    var id: String { keyName }
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

    enum Mode {
        case list
        case customConnector(CustomConnectorModel)
    }

    enum CapabilitiesPhase: Equatable {
        case hidden
        case loading
        case ready([CapabilityRow])
        case failed
    }

    private(set) var phase: Phase = .loading
    private(set) var capabilitiesPhase: CapabilitiesPhase = .hidden
    private(set) var catalog = ConnectCatalog()
    private(set) var deviceRows: [DeviceRow] = []
    private(set) var busy: Set<String> = []
    var selection = ConnectChip.all
    var query = ""
    var page: Page = .catalog
    var notice: ConnectNotice?
    var credentialPrompt: CredentialPrompt?
    var keyRequest: CapabilityKeyRequest?
    private(set) var keyState: SecretEntryState = .idle
    var disconnectTarget: ConnectDisconnectTarget?
    var showsSkills = false
    private(set) var mode: Mode = .list

    let botName: String
    private let profile: String?
    private let service: ConnectAppsService
    private let capabilitiesService: CapabilitiesService
    private let skillsService: SkillsCatalogService
    private let bots: [CustomConnectorBot]
    private let currentBot: String?
    private let pool: DeviceHostPool
    private let permissions = SystemPermissions()
    private let diagnostics = Diagnostics.osLog()
    private var statuses: [DeviceConnectorStatus] = []
    private var localPermissions: [DeviceConnectorID: DeviceOSPermission] = [:]
    private var ledger: ConnectorLedger?
    private var observation: UUID?

    init(
        connection: ConnectionModel, pool: DeviceHostPool, profile: String?, botName: String, browser: any AuthorizationBrowser,
        bots: [CustomConnectorBot] = [], currentBot: String? = nil
    ) {
        self.profile = profile
        self.botName = botName
        self.pool = pool
        self.bots = bots
        self.currentBot = currentBot
        service = ConnectAppsService(
            rpc: ConnectionRPC(model: connection), profile: profile, browser: browser,
            systemBrowser: SystemBrowserAuthorization(), diagnostics: .osLog()
        )
        skillsService = SkillsCatalogService(rpc: ConnectionRPC(model: connection), profile: profile, diagnostics: .osLog())
        capabilitiesService = CapabilitiesService(gateway: BotsGateway { method, params in try await connection.rpc(method, params) })
        rebuildDeviceRows()
    }

    var customConnector: CustomConnectorModel? {
        if case .customConnector(let connector) = mode { connector } else { nil }
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
        await loadCapabilities()
    }

    func loadCapabilities() async {
        guard let profile else { return }
        if case .ready = capabilitiesPhase {} else { capabilitiesPhase = .loading }
        do {
            capabilitiesPhase = .ready(try await capabilitiesService.status(profile: profile))
        } catch is CancellationError {
            return
        } catch {
            diagnostics.info("capabilities", "status failed: \(Diagnostics.describe(error))")
            if case .ready = capabilitiesPhase {} else { capabilitiesPhase = .failed }
        }
    }

    func makeSkillsModel() -> SkillsCatalogModel { SkillsCatalogModel(service: skillsService) }

    var canSetKeys: Bool { profile != nil }

    func beginKeyEntry(_ row: CapabilityRow, keyName: String) {
        guard canSetKeys, row.settableKeys.contains(keyName) else { return }
        keyState = .idle
        keyRequest = CapabilityKeyRequest(capability: row.label, keyName: keyName)
    }

    func cancelKeyEntry() {
        keyRequest = nil
        keyState = .idle
    }

    func submitKey(_ value: String) async {
        guard let request = keyRequest, let profile, keyState.acceptsInput else { return }
        keyState = .submitting
        do {
            capabilitiesPhase = .ready(try await capabilitiesService.setKey(request.keyName, to: SecretString(value), profile: profile))
            cancelKeyEntry()
        } catch is CancellationError {
            keyState = .idle
        } catch {
            diagnostics.info("capabilities", "set key failed: \(Diagnostics.describe(error))")
            keyState = .failure(String(localized: "Couldn't save the key. Check it and try again."))
        }
    }

    func stop() async {
        await customConnector?.discard()
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
        deviceRows = PlatformCapabilities.deviceConnectors.map { id in
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
            return DeviceRow(
                id: id, title: status?.title ?? defaults.title, subtitle: status?.subtitle ?? defaults.subtitle,
                action: action, warning: DeviceConnectorDefaults.warning(for: id)
            )
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
                report("\(row.title) isn't available on this device.")
            }
        } catch {
            diagnostics.info("device", "allow \(row.id.rawValue) failed: \(Diagnostics.describe(error))")
            report("Couldn't turn on \(row.title). Try again.")
        }
        rebuildDeviceRows()
    }

    func setEnabled(_ row: DeviceRow, _ isOn: Bool) async {
        if isOn { await allow(row) } else { await turnOff(row) }
    }

    func turnOff(_ row: DeviceRow) async {
        guard let ledger else { return }
        do { try await ledger.set(row.id, state: .off) } catch { report("Couldn't turn off \(row.title). Try again.") }
        rebuildDeviceRows()
    }

    func openSettings() {
        guard let url = SystemSettings.appSettingsURL else { return }
        SystemSettings.open(url)
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

    func addCustomConnector() {
        mode = .customConnector(makeCustomConnector(existing: nil))
    }

    func manage(_ app: ConnectApp) {
        guard case .custom(let info) = app.source else { return }
        mode = .customConnector(makeCustomConnector(existing: info))
    }

    func leaveCustomConnector() async {
        await customConnector?.discard()
        mode = .list
        await reload()
    }

    private func makeCustomConnector(existing: CustomConnectorInfo?) -> CustomConnectorModel {
        CustomConnectorModel(
            service: service, existing: existing, bots: bots, currentBot: currentBot,
            reload: { [weak self] in await self?.reload() },
            leave: { [weak self] in self?.mode = .list }
        )
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
