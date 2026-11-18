import Foundation
import PalAuth
import PalBotProfile
import PalClient
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

@MainActor
@Observable
final class ConnectAppsModel {
    enum Phase: Equatable {
        case loading
        case ready
        case unavailable
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
    var capabilitiesPhase: CapabilitiesPhase = .hidden
    private(set) var catalog = ConnectCatalog()
    var busy: Set<String> = []
    var query = ""
    var notice: ConnectNotice?
    var credentialPrompt: CredentialPrompt?
    var keyRequest: CapabilityKeyRequest?
    var keyState: SecretEntryState = .idle
    var disconnectTarget: ConnectDisconnectTarget?
    var showsSkills = false
    var mcpSignIn: McpSignInController?
    var ownerSetup: OwnerSetupModel?
    var showsSlackPicker = false
    var discordFlow: DiscordFlowSession?
    let slack: SlackBotsModel
    let slackWizard: SlackWizardContext
    var pasteSession: (any McpPasteSigning)?
    var pastingApp: ConnectApp?
    var pasteTargetID = UpworkConnector.service
    var pasteState: SecretEntryState = .idle
    var failures: [String: String] = [:]
    private(set) var mode: Mode = .list

    let botName: String
    let devices: DeviceConnectorsModel
    let profile: String?
    let service: ConnectAppsService
    let legacy: LegacyConnectionsModel
    let capabilitiesService: CapabilitiesService
    private let skillsService: SkillsCatalogService
    private let bots: [CustomConnectorBot]
    private let currentBot: String?
    let diagnostics = Diagnostics.osLog()
    let surfaces: SurfaceCache
    private var catalogKey: SurfaceKey { .screen("connect-catalog", bot: profile ?? "") }
    var capabilitiesKey: SurfaceKey { .screen("connect-capabilities", bot: profile ?? "") }

    init(
        connection: ConnectionModel, pool: DeviceHostPool, profile: String?, botName: String, browser: any AuthorizationBrowser,
        bots: [CustomConnectorBot] = [], currentBot: String? = nil
    ) {
        slackWizard = SlackWizardContext(bots: bots, connection: connection)
        slack = SlackBotsModel(bots: slackWizard.slackBots())
        self.profile = profile
        self.botName = botName
        devices = DeviceConnectorsModel(pool: pool, profile: profile, surfaces: connection.surfaces)
        self.bots = bots
        self.currentBot = currentBot
        let connectService = ConnectAppsService(
            rpc: OAuthClientScript.wrap(McpSignInScript.wrap(ConnectionRPC(model: connection))), profile: profile,
            browser: McpSignInScript.browser(OAuthClientScript.browser(browser)),
            systemBrowser: SystemBrowserAuthorization(), nativeSignIn: NativeMcpSignIn.native(connection: connection), diagnostics: .osLog()
        )
        service = connectService
        legacy = LegacyConnectionsModel(service: connectService, profile: profile)
        skillsService = SkillsCatalogService(rpc: ConnectionRPC(model: connection), profile: profile, diagnostics: .osLog())
        capabilitiesService = CapabilitiesService(gateway: BotsGateway { method, params in try await connection.rpc(method, params) })
        surfaces = connection.surfaces
        if let held = surfaces.remembered(ConnectCatalog.self, catalogKey) {
            catalog = held
            phase = .ready
        }
        if profile != nil, let rows = surfaces.remembered([CapabilityRow].self, capabilitiesKey) {
            capabilitiesPhase = .ready(rows)
        }
    }

    var customConnector: CustomConnectorModel? {
        if case .customConnector(let connector) = mode { connector } else { nil }
    }

    var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var searchedApps: [ConnectApp] { catalog.matching(trimmedQuery) }

    var searchedSkills: [InstalledSkill] { catalog.matchingSkills(trimmedQuery) }

    func start() async {
        Task { await devices.start() }
        Task { await legacy.load() }
        Task { await slack.load() }
        await reload()
        await loadCapabilities()
    }

    func makeSkillsModel() -> SkillsCatalogModel { SkillsCatalogModel(service: skillsService, profile: profile, surfaces: surfaces) }

    func stop() async {
        await customConnector?.discard()
    }

    func reload() async {
        do {
            catalog = try await service.load()
            phase = .ready
            surfaces.remember(catalog, catalogKey)
        } catch {
            if catalog.apps.isEmpty { phase = .unavailable }
        }
    }

    func connect(_ app: ConnectApp, credentials: [String: String] = [:]) async {
        if presentsDiscordFlow(app) || presentsSetupGuide(app) { return }
        if app.usesMcpSignIn {
            beginMcpSignIn(app)
            return
        }
        busy.insert(app.id)
        failures[app.id] = nil
        defer { busy.remove(app.id) }
        do {
            try await service.connect(app, credentials: credentials)
            if let failure = await service.tokenFailure(app) {
                report(failure == .authRefused ? "\(app.name) didn't accept that token. Check it and try again." : failure.message)
            }
        } catch let error as ConnectAppsError {
            handle(error, app: app)
        } catch {
            fail(app, "Couldn't connect \(app.name). Try again.")
        }
        await reload()
    }

    func beginMcpSignIn(_ app: ConnectApp) {
        guard mcpSignIn == nil else { return }
        failures[app.id] = nil
        mcpSignIn = McpSignInController(
            app: app, service: service, platform: ConnectorPlatform.current,
            openLink: { ExternalLink.open($0) },
            finished: { [weak self] in await self?.reload() }
        )
    }

    func manageAccounts(_ app: ConnectApp) {
        disconnectTarget = .app(app)
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

    func handle(_ error: ConnectAppsError, app: ConnectApp) {
        switch error {
        case .cancelled:
            if app.requiresAppSignIn { failures[app.id] = McpOAuthError.cancelled.reason }
        case .signInFailed(let reason): failures[app.id] = reason
        case .signInRefused(let failure, _): failures[app.id] = failure.reason
        case .credentialsRequired(let keys): credentialPrompt = CredentialPrompt(app: app, keys: keys)
        case .unavailable, .failed, .faulted, .oauthClient, .adminApprovalPending: fail(app, "Couldn't connect \(app.name). Try again.")
        }
    }

    func fail(_ app: ConnectApp, _ message: String) {
        if app.requiresAppSignIn {
            failures[app.id] = message
        } else {
            report(message)
        }
    }

    func report(_ message: String) {
        notice = ConnectNotice(title: "Connect apps", message: message)
    }
}
