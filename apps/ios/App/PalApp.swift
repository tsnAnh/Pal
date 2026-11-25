import AppIntents
import PalBotProfile
import PalChat
import PalClient
import PalConnect
import PalDesign
import PalDevice
import PalDiagnostics
import SwiftUI

@main
struct PalApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #elseif os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif
    @State private var model: ConnectionModel
    @State private var roster: RosterModel
    @State private var offers: ReachOfferModel
    @State private var router: AppRouter
    @State private var appearance: AppearanceStore
    @State private var consent: DevicePermissionPresenter
    @State private var hostPool: DeviceHostPool
    @State private var signIn: ServiceSignInCenter
    @State private var autoApprove: ActionAutoApprove
    @State private var heldDrafts: HeldDraftsModel
    @State private var links: BotLinks
    @State private var chatModels = ChatModelCache()
    @State private var bots: BotsKit
    @State private var templateImport: TemplateImportModel
    @State private var rooms: RoomsModel
    @State private var hub: SettingsHub
    @State private var directory = BotDirectory()
    #if os(macOS)
    @State private var shell = MacShell()
    @State private var shortcuts = ShortcutStore()
    #endif
    @Environment(\.scenePhase) private var scenePhase

    init() {
        LaunchClock.begin()
        LaunchPreferences.applyReset()
        let model = ConnectionModel.live()
        _model = State(initialValue: model)
        let roster = RosterModel(connection: model)
        _roster = State(initialValue: roster)
        let router = AppRouter(capabilities: [.botProfile, .connectApps, .kanban])
        _router = State(initialValue: router)
        _appearance = State(initialValue: AppearanceStore())
        let consent = DevicePermissionPresenter { profile in roster.displayName(forProfile: profile) }
        _consent = State(initialValue: consent)
        _hostPool = State(initialValue: DeviceHostPool(connection: model, consent: consent))
        let signIn = ServiceSignInCenter(
            call: { method, params in try await model.rpc(method, params) },
            openBrowser: { _ = ExternalLink.open($0) },
            nativeSignIn: NativeMcpSignIn.serviceHandler(connection: model),
            pasteSignIn: .routing(
                [GoogleWorkspaceCatalog.serviceID: GoogleSignIn.servicePasteRoute(connection: model)],
                fallback: NativeMcpSignIn.servicePasteRoute(connection: model)
            ),
            pasteOnlyServices: [GoogleWorkspaceCatalog.serviceID]
        )
        _signIn = State(initialValue: signIn)
        _autoApprove = State(initialValue: ActionAutoApprove { method, params in try await model.rpc(method, params) })
        _heldDrafts = State(initialValue: HeldDraftsModel(
            source: HeldDraftFixture.source(arguments: ProcessInfo.processInfo.arguments)
                ?? HeldDraftDesk(connector: LiveChatConnector(connection: model))
        ))
        roster.gatewayEventSink = { event in
            Task { @MainActor in signIn.receive(event) }
        }
        _offers = State(initialValue: ReachOfferModel(presence: model.presence) { sessionID in
            router.openChat(sessionID: sessionID, in: roster)
        })
        let links = BotLinks(connection: model)
        _links = State(initialValue: links)
        let kit = BotsKit(connection: model)
        _bots = State(initialValue: kit)
        _templateImport = State(initialValue: TemplateImportModel(client: kit.services.templateImport))
        _rooms = State(initialValue: RoomsModel(services: kit.services, roster: roster))
        _hub = State(initialValue: SettingsHub(connection: model, roster: roster))
        let environment = IntentEnvironment(connection: model, roster: roster, router: router, links: links)
        AppDependencyManager.shared.add(dependency: environment)
        LaunchClock.mark("app initialised", on: .osLog())
    }

    var body: some Scene {
        WindowGroup {
            RootView(
                model: model, roster: roster, router: router, hostPool: hostPool, links: links, chatModels: chatModels,
                bots: bots, templateImport: templateImport, rooms: rooms, hub: hub
            )
                .overlay { ReachOfferOverlay(model: offers) }
                .overlay(alignment: .topLeading) { ExternalLinkProbe() }
                .devicePermissionAlert(consent)
                .serviceSignInDialog(signIn) { roster.displayName(forProfile: $0) }
                .hermesTheme(mode: appearance.mode)
                .environment(appearance)
                .environment(signIn)
                .environment(autoApprove)
                .environment(\.heldDrafts, heldDrafts)
                #if os(macOS)
                .environment(shell)
                .environment(shortcuts)
                #endif
                .macWindowSizing()
                .onOpenURL { url in
                    guard ChatInstallLink(url: url) != nil, let bot = ChatInstallReturn.take(), roster.bot(named: bot) != nil else { return }
                    router.openSlack(botName: bot)
                }
                .task { await model.restore() }
                .task { await offers.listen() }
                .task { await FrameMonitor.startIfRequested() }
                .task {
                    appDelegate.push.attach(presence: model.presence) { target in
                        router.openChat(from: target, in: roster)
                    }
                }
                .modifier(
                    AppObservers(
                        model: model, roster: roster, router: router, hostPool: hostPool, autoApprove: autoApprove,
                        directory: directory, push: appDelegate.push, scenePhase: scenePhase
                    )
                )
        }
        #if os(macOS)
        .defaultSize(width: MacLayoutMetrics.defaultWindowWidth, height: MacLayoutMetrics.defaultWindowHeight)
        .defaultLaunchBehavior(TestHostMode.isActive ? .suppressed : .automatic)
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
        .commands { MacCommands(shell: shell, roster: roster, router: router, connection: model, shortcuts: shortcuts, updater: appDelegate.updater) }
        #endif
    }
}

struct RootView: View {
    let model: ConnectionModel
    let roster: RosterModel
    @Bindable var router: AppRouter
    let hostPool: DeviceHostPool
    let links: BotLinks
    let chatModels: ChatModelCache
    let bots: BotsKit
    let rooms: RoomsModel
    let hub: SettingsHub
    @State private var createBot = CreateBotModel()
    @State private var templateImport: TemplateImportModel
    #if os(iOS)
    @SceneStorage("pal.openChat") private var restoredChat = ""
    @State private var didRestoreChat = false
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    init(
        model: ConnectionModel, roster: RosterModel, router: AppRouter, hostPool: DeviceHostPool, links: BotLinks,
        chatModels: ChatModelCache, bots: BotsKit, templateImport: TemplateImportModel, rooms: RoomsModel, hub: SettingsHub
    ) {
        self.model = model
        self.roster = roster
        self.router = router
        self.hostPool = hostPool
        self.links = links
        self.chatModels = chatModels
        self.bots = bots
        self.rooms = rooms
        self.hub = hub
        _templateImport = State(initialValue: templateImport)
    }

    private func resetCreateBot() {
        createBot = CreateBotModel()
        templateImport = TemplateImportModel(client: bots.services.templateImport)
    }

    #if os(iOS)
    private var sheetItem: Binding<AppSheet?> {
        Binding(
            get: { router.sheet == .kanban ? nil : router.sheet },
            set: { if router.sheet != .kanban { router.sheet = $0 } }
        )
    }
    #endif

    private var showsWorkspace: Bool {
        model.isConnected || (model.phase == .connecting && roster.hasContent)
    }

    @ViewBuilder
    private var navigation: some View {
        #if os(iOS)
        AdaptiveNavigation(path: $router.path) {
            HomeView(roster: roster, connection: model, router: router)
        } destination: { route in
            destination(route)
        } placeholder: {
            ContentUnavailableView {
                Label("Pick a bot", palIcon: "bubble.left.and.bubble.right")
            } description: { Text("Choose a bot from the list to start chatting.") }
        }
        #else
        MacShellView(roster: roster, connection: model, router: router, bots: bots) { route in
            destination(route)
        }
        #endif
    }

    var body: some View {
        if showsWorkspace {
            workspace.macModalEnvironment()
        } else if model.phase == .connecting {
            DelayedReveal { ProgressView("Connecting") }
                .accessibilityIdentifier("connectingIndicator")
        } else {
            ConnectionView(model: model)
        }
    }

    @ViewBuilder
    private var workspace: some View {
        navigation
            .environment(hub)
            .environment(rooms)
            .task { await roster.runLive() }
            .task { await rooms.run() }
            .macSheet(isPresented: Binding(get: { rooms.showsCreate }, set: { rooms.showsCreate = $0 }), size: .form) {
                CreateRoomSheet(rooms: rooms, roster: roster, router: router)
            }
            .ownerIntro(hub: hub, connection: model, router: router)
            .onChange(of: roster.bots, initial: true) { _, _ in router.dropUnresolvedChat(in: roster) }
            .onChange(of: roster.bots.map(\.name)) { _, names in
                guard model.isConnected else { return }
                Task { await hostPool.startHosts(botNames: names) }
            }
            .onAppear {
                router.registerShareAsTemplate { name in Task { await bots.sharer.share(botName: name) } }
            }
            .task(id: model.isConnected) {
                guard model.isConnected else { return }
                await hostPool.startHosts(botNames: roster.bots.map(\.name))
            }
            .task(id: roster.isLoaded) {
                guard roster.isLoaded, ProcessInfo.processInfo.arguments.contains(ConnectAppsLaunch.argument) else { return }
                router.presentConnectApps()
            }
            #if os(iOS)
            .onChange(of: roster.bots, initial: true) { _, _ in settleOpenConversation() }
            .onChange(of: roster.isLoaded) { _, _ in settleOpenConversation() }
            .onChange(of: router.path.isEmpty) { _, _ in settleOpenConversation() }
            .onChange(of: sizeClass) { _, _ in settleOpenConversation() }
            .onChange(of: router.currentBotName) { _, name in rememberOpenConversation(name) }
            .sheet(item: sheetItem, onDismiss: { resetCreateBot() }) { sheet in
                Group {
                    switch sheet {
                    case .settings:
                        SettingsSheet(model: model, hub: hub, initialRoute: router.settingsRoute, openConnectApps: { router.presentConnectApps() }) { router.dismissSheet() }
                    case .createBot:
                        CreateBotSheet(model: createBot, importer: templateImport, roster: roster, router: router)
                    case .connectApps:
                        ModelHost {
                            ConnectAppsModel(
                                connection: model,
                                pool: hostPool,
                                profile: router.connectAppsProfile,
                                botName: roster.displayName(forProfile: router.connectAppsProfile),
                                browser: WebAuthenticationBrowser(),
                                bots: roster.customConnectorBots,
                                currentBot: roster.currentBotName(forProfile: router.connectAppsProfile)
                            )
                        } content: {
                            ConnectAppsScreen(model: $0) { router.dismissSheet() }
                        }
                    case .approvals:
                        ApprovalsView(bots: roster.heldDraftBots(for: router.approvalsProfile)) { router.dismissSheet() }
                    case .kanban:
                        EmptyView()
                    }
                }
                .serviceSignInDialogHost()
            }
            .fullCover(isPresented: $router.isKanbanPresented) {
                KanbanSurface(connection: model, roster: roster) { router.dismissSheet() }
            }
            .fullCover(isPresented: $router.isSearching) {
                SearchHost(roster: roster, router: router)
            }
            #else
            .overlay(alignment: .top) { ScreenCaptureBadge(indicator: hostPool.screenIndicator) }
            .overlay {
                MacModalHost(connection: model, roster: roster, router: router, hostPool: hostPool, createBot: createBot, hub: hub)
            }
            .onChange(of: router.sheet) { _, sheet in
                if sheet == nil { resetCreateBot() }
            }
            #endif
    }
}

#if os(iOS)
extension RootView {
    private func settleOpenConversation() {
        guard router.path.isEmpty else {
            didRestoreChat = true
            return
        }
        if ShellLayout.usesSplit(sizeClass) {
            if let bot = roster.launchBot { router.openChat(botName: bot.name) }
            return
        }
        guard !didRestoreChat else { return }
        guard !restoredChat.isEmpty else {
            didRestoreChat = true
            return
        }
        if roster.bot(named: restoredChat) != nil {
            didRestoreChat = true
            router.openChat(botName: restoredChat)
        } else if roster.isLoaded {
            didRestoreChat = true
            restoredChat = ""
        }
    }

    private func rememberOpenConversation(_ name: String?) {
        restoredChat = name ?? ""
        if let name, roster.bot(named: name) != nil { roster.rememberOpened(bot: name) }
    }
}
#endif
