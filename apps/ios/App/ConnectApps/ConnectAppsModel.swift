import Foundation
import PalAuth
import PalBotProfile
import PalConnect
import PalDesign
import PalDevice
import PalDiagnostics
import PalProtocol
import Observation

struct ConnectionRPC: ConnectRPC {
    let model: ConnectionModel

    func call(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        try await model.rpc(method, params)
    }
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

    var id: String {
        switch self {
        case .app(let app): app.id
        }
    }

    var name: String {
        switch self {
        case .app(let app): app.name
        }
    }
}

enum ConnectChip {
    static let all = "all"
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
    var accountsModel: ConnectorAccountsModel?
    var upworkApp: ConnectApp?
    private(set) var pasteSession: McpPasteSession?
    private(set) var pasteState: SecretEntryState = .idle
    private(set) var failures: [String: String] = [:]
    private(set) var mode: Mode = .list

    let botName: String
    private let profile: String?
    private let service: ConnectAppsService
    private let capabilitiesService: CapabilitiesService
    private let skillsService: SkillsCatalogService
    let github: GitHubAccountModel
    private let bots: [CustomConnectorBot]
    private let currentBot: String?
    private let diagnostics = Diagnostics.osLog()

    init(
        connection: ConnectionModel, profile: String?, botName: String, browser: any AuthorizationBrowser,
        bots: [CustomConnectorBot] = [], currentBot: String? = nil
    ) {
        self.profile = profile
        self.botName = botName
        self.bots = bots
        self.currentBot = currentBot
        service = ConnectAppsService(
            rpc: ConnectionRPC(model: connection), profile: profile, browser: browser,
            systemBrowser: SystemBrowserAuthorization(), nativeSignIn: UpworkSignIn.native(connection: connection), diagnostics: .osLog()
        )
        skillsService = SkillsCatalogService(rpc: ConnectionRPC(model: connection), profile: profile, diagnostics: .osLog())
        let gateway = BotsGateway { method, params in try await connection.rpc(method, params) }
        capabilitiesService = CapabilitiesService(gateway: gateway)
        github = GitHubAccountModel(client: GitHubClient(gateway: gateway))
    }

    var customConnector: CustomConnectorModel? {
        if case .customConnector(let connector) = mode { connector } else { nil }
    }

    var connectedCount: Int { catalog.connectedApps.count }

    var connectedApps: [ConnectApp] { catalog.connectedApps }

    var chips: [String] { [ConnectChip.all] + catalog.categories }

    var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var searchedApps: [ConnectApp] { catalog.matching(trimmedQuery) }

    var searchedSkills: [InstalledSkill] { catalog.matchingSkills(trimmedQuery) }

    func start() async {
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
    }

    func reload() async {
        do {
            catalog = try await service.load()
            phase = .ready
        } catch {
            if catalog.apps.isEmpty { phase = .unavailable }
        }
    }

    func cardState(_ app: ConnectApp) -> ConnectorCardState {
        return .resolve(ConnectorCardInput(app: app, isBusy: busy.contains(app.id), failureReason: failures[app.id]))
    }

    var isPastingAddress: Bool { pasteSession != nil }

    func beginPaste(_ app: ConnectApp) async {
        guard pasteSession == nil else { return }
        busy.insert(app.id)
        failures[app.id] = nil
        defer { busy.remove(app.id) }
        do {
            let session = try await service.beginUpworkPaste(app)
            guard ExternalLink.open(session.authorizeURL) else {
                await session.cancel()
                failures[app.id] = McpOAuthError.browserUnavailable.reason
                return
            }
            pasteSession = session
            pasteState = .idle
        } catch let error as ConnectAppsError {
            handle(error, app: app)
        } catch {
            report("Couldn't connect \(app.name). Try again.")
        }
        await reload()
    }

    func submitPastedAddress(_ value: String) async {
        guard let session = pasteSession, pasteState.acceptsInput else { return }
        pasteState = .submitting
        switch await session.submit(value) {
        case .signedIn:
            pasteSession = nil
            pasteState = .idle
        case .tryAgain(let note):
            pasteState = .failure(note)
        case .failed(let reason):
            pasteSession = nil
            pasteState = .idle
            failures[UpworkConnector.service] = reason
        }
        await reload()
    }

    func reopenPasteSignIn() {
        if let url = pasteSession?.authorizeURL { ExternalLink.open(url) }
    }

    func cancelPaste() async {
        guard let session = pasteSession else { return }
        pasteSession = nil
        pasteState = .idle
        await session.cancel()
        await reload()
    }

    func connect(_ app: ConnectApp, credentials: [String: String] = [:]) async {
        busy.insert(app.id)
        failures[app.id] = nil
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

    func manageAccounts(_ app: ConnectApp) {
        if app.requiresAppSignIn {
            upworkApp = app
            return
        }
        guard case .hosted(let slug) = app.source else { return }
        accountsModel = ConnectorAccountsModel(
            app: app, slug: slug, botName: botName, service: service,
            changed: { [weak self] in await self?.reload() }
        )
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
        case .signInFailed(let reason): failures[app.id] = reason
        case .credentialsRequired(let keys): credentialPrompt = CredentialPrompt(app: app, keys: keys)
        case .signInRequired: report("Connecting \(app.name) needs you to sign in to Nous Portal on your Pal first.")
        case .unavailable, .failed: report("Couldn't connect \(app.name). Try again.")
        }
    }

    private func report(_ message: String) {
        notice = ConnectNotice(title: "Connect apps", message: message)
    }
}
