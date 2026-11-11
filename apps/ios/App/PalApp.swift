import AppIntents
import PalBotProfile
import PalClient
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
    @State private var consent: DeviceConsentPresenter
    @State private var hostPool: DeviceHostPool
    @State private var signIn: ServiceSignInCenter
    @State private var links: BotLinks
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
        let router = AppRouter(capabilities: [.botProfile, .connectApps])
        _router = State(initialValue: router)
        _appearance = State(initialValue: AppearanceStore())
        let consent = DeviceConsentPresenter { profile in roster.displayName(forProfile: profile) }
        _consent = State(initialValue: consent)
        _hostPool = State(initialValue: DeviceHostPool(connection: model, consent: consent))
        let signIn = ServiceSignInCenter(
            call: { method, params in try await model.rpc(method, params) },
            openBrowser: { _ = ExternalLink.open($0) }
        )
        _signIn = State(initialValue: signIn)
        roster.gatewayEventSink = { event in
            Task { @MainActor in signIn.receive(event) }
        }
        _offers = State(initialValue: ReachOfferModel(presence: model.presence) { sessionID in
            router.openChat(sessionID: sessionID, in: roster)
        })
        let links = BotLinks(connection: model)
        _links = State(initialValue: links)
        let environment = IntentEnvironment(connection: model, roster: roster, router: router, links: links)
        AppDependencyManager.shared.add(dependency: environment)
        LaunchClock.mark("app initialised", on: .osLog())
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: model, roster: roster, router: router, hostPool: hostPool, links: links)
                .overlay { ReachOfferOverlay(model: offers) }
                .overlay(alignment: .topLeading) { ExternalLinkProbe() }
                .deviceConsentAlert(consent)
                .serviceSignInDialog(signIn) { roster.displayName(forProfile: $0) }
                .hermesTheme(mode: appearance.mode, botAccent: roster.accentBot?.accent)
                .environment(appearance)
                .environment(signIn)
                #if os(macOS)
                .environment(shell)
                .environment(shortcuts)
                #endif
                .macWindowSizing()
                .task { await model.restore() }
                .task { await offers.listen() }
                .task {
                    appDelegate.push.attach(presence: model.presence) { target in
                        router.openChat(from: target, in: roster)
                    }
                }
                .onChange(of: model.isConnected, initial: true) { _, connected in
                    if connected { Task { await appDelegate.push.ensureRegistered() } }
                }
                .onChange(of: roster.bots) { _, bots in
                    Task { await directory.publish(bots) }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await model.restore() } }
                }
                .onChange(of: model.phase) { _, phase in
                    guard phase == .signedOut else { return }
                    roster.reset()
                    router.popToRoot()
                    Task { await hostPool.reset() }
                }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    model.report(attention: ReachAttention(sceneIsActive: phase == .active))
                }
        }
        #if os(macOS)
        .defaultSize(width: 1280, height: 830)
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
        .commands { MacCommands(shell: shell, roster: roster, router: router, connection: model, shortcuts: shortcuts) }
        #endif
    }
}

struct RootView: View {
    let model: ConnectionModel
    let roster: RosterModel
    @Bindable var router: AppRouter
    let hostPool: DeviceHostPool
    let links: BotLinks
    @State private var createBot = CreateBotModel()
    @State private var bots: BotsKit
    @State private var rooms: RoomsModel
    @State private var hub: SettingsHub
    #if os(iOS)
    @SceneStorage("pal.openChat") private var restoredChat = ""
    @State private var didRestoreChat = false
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    init(model: ConnectionModel, roster: RosterModel, router: AppRouter, hostPool: DeviceHostPool, links: BotLinks) {
        self.model = model
        self.roster = roster
        self.router = router
        self.hostPool = hostPool
        self.links = links
        let kit = BotsKit(connection: model)
        _bots = State(initialValue: kit)
        _rooms = State(initialValue: RoomsModel(services: kit.services, roster: roster))
        _hub = State(initialValue: SettingsHub(connection: model, roster: roster))
    }

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
            ContentUnavailableView("Pick a bot", systemImage: "bubble.left.and.bubble.right", description: Text("Choose a bot from the list to start chatting."))
        }
        #else
        MacShellView(roster: roster, connection: model, router: router, bots: bots) { route in
            destination(route)
        }
        #endif
    }

    @ViewBuilder
    private func destination(_ route: AppRoute) -> some View {
        switch route {
        case .chat(let name):
            if let bot = roster.bot(named: name) {
                ChatView(
                    model: ChatModel(bot: bot, links: links, roster: roster),
                    teach: bots.teach(for: name, displayName: bot.displayName),
                    router: router
                )
            }
        case .room(let roomID):
            if let room = rooms.room(id: roomID), let service = rooms.service {
                RoomView(model: RoomModel(room: room, service: service, rooms: rooms), roster: roster, router: router)
            }
        case .botProfile(let name):
            BotProfileView(
                model: BotProfileModel(botName: name, services: bots.services, roster: roster, sharer: bots.sharer),
                suggestions: ConnectedServicesModel(botName: name, services: bots.services),
                router: router
            )
        case .botThread(let thread):
            BotThreadView(model: BotThreadModel(route: thread, connection: model, roster: roster))
        case .library(let name):
            LibraryView(model: LibraryModel(botName: name, services: bots.services))
        case .routines(let name):
            RoutinesView(model: RoutinesModel(botName: name, services: bots.services))
        case .computer(let name):
            let bot = roster.bot(named: name)
            ComputerView(
                model: ComputerModel(
                    botName: name,
                    service: bots.services.computer,
                    openStream: bots.services.openDisplayStream
                ),
                teach: bots.teach(for: name, displayName: bot?.displayName ?? name),
                title: bot?.displayName ?? name,
                spec: bot?.spec
            )
        case .slack(let name):
            SlackView(model: SlackModel(
                botName: name,
                displayName: roster.bot(named: name)?.displayName ?? name,
                services: bots.services
            ))
        case .telegram(let name):
            TelegramView(model: TelegramModel(
                botName: name,
                displayName: roster.bot(named: name)?.displayName ?? name,
                services: bots.services
            ))
        case .botModel(let name):
            BotModelView(
                model: BotModelsModel(client: bots.services.models(name)),
                displayName: roster.bot(named: name)?.displayName ?? name
            )
        case .messagingSettings(let name):
            MessagingSettingsView(model: MessagingSettingsModel(
                botName: name,
                displayName: roster.bot(named: name)?.displayName ?? name,
                services: bots.services
            ))
        }
    }

    var body: some View {
        if showsWorkspace {
            workspace
        } else if model.phase == .connecting {
            ProgressView("Connecting")
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
            .sheet(isPresented: Binding(get: { rooms.showsCreate }, set: { rooms.showsCreate = $0 })) {
                CreateRoomSheet(rooms: rooms, roster: roster, router: router)
            }
            .onChange(of: roster.bots, initial: true) { _, _ in router.dropUnresolvedChat(in: roster) }
            .onAppear {
                router.registerShareAsTemplate { name in Task { await bots.sharer.share(botName: name) } }
            }
            .task(id: model.isConnected) {
                guard model.isConnected else { return }
                await hostPool.resumeSavedHosts()
                if ProcessInfo.processInfo.arguments.contains(ConnectAppsLaunch.argument) { router.presentConnectApps() }
            }
            #if os(iOS)
            .onChange(of: roster.bots, initial: true) { _, _ in settleOpenConversation() }
            .onChange(of: roster.isLoaded) { _, _ in settleOpenConversation() }
            .onChange(of: router.path.isEmpty) { _, _ in settleOpenConversation() }
            .onChange(of: sizeClass) { _, _ in settleOpenConversation() }
            .onChange(of: router.currentBotName) { _, name in rememberOpenConversation(name) }
            .sheet(item: $router.sheet, onDismiss: { createBot = CreateBotModel() }) { sheet in
                switch sheet {
                case .settings:
                    SettingsSheet(model: model, hub: hub, initialRoute: router.settingsRoute, openConnectApps: { router.presentConnectApps() }) { router.dismissSheet() }
                case .createBot:
                    CreateBotSheet(model: createBot, roster: roster, router: router)
                case .connectApps:
                    ConnectAppsSheet(
                        model: ConnectAppsModel(
                            connection: model,
                            pool: hostPool,
                            profile: router.connectAppsProfile,
                            botName: roster.displayName(forProfile: router.connectAppsProfile),
                            browser: WebAuthenticationBrowser(),
                            bots: roster.customConnectorBots,
                            currentBot: roster.currentBotName(forProfile: router.connectAppsProfile)
                        )
                    ) { router.dismissSheet() }
                }
            }
            .fullCover(isPresented: $router.isSearching) {
                SearchHost(roster: roster, router: router)
            }
            #else
            .overlay {
                MacModalHost(connection: model, roster: roster, router: router, hostPool: hostPool, createBot: createBot, hub: hub)
            }
            .onChange(of: router.sheet) { _, sheet in
                if sheet == nil { createBot = CreateBotModel() }
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
