import HermesClient
import HermesDesign
import SwiftUI

@main
struct HermesBotsApp: App {
    @State private var model: ConnectionModel
    @State private var roster: RosterModel
    @State private var offers: ReachOfferModel
    @State private var router: AppRouter
    @State private var appearance: AppearanceStore
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let model = ConnectionModel.live()
        _model = State(initialValue: model)
        let roster = RosterModel(connection: model)
        _roster = State(initialValue: roster)
        let router = AppRouter(capabilities: [.botProfile])
        _router = State(initialValue: router)
        _appearance = State(initialValue: AppearanceStore())
        _offers = State(initialValue: ReachOfferModel(presence: model.presence) { sessionID in
            router.openChat(sessionID: sessionID, in: roster)
        })
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: model, roster: roster, router: router)
                .overlay { ReachOfferOverlay(model: offers) }
                .hermesTheme(mode: appearance.mode, botAccent: roster.accentBot?.accent)
                .task { await model.restore() }
                .task { await offers.listen() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await model.restore() } }
                }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    model.report(attention: ReachAttention(sceneIsActive: phase == .active))
                }
        }
    }
}

struct RootView: View {
    let model: ConnectionModel
    let roster: RosterModel
    @Bindable var router: AppRouter
    @State private var createBot = CreateBotModel()
    @State private var bots: BotsKit

    init(model: ConnectionModel, roster: RosterModel, router: AppRouter) {
        self.model = model
        self.roster = roster
        self.router = router
        _bots = State(initialValue: BotsKit(connection: model))
    }

    var body: some View {
        switch model.phase {
        case .connected:
            NavigationStack(path: $router.path) {
                HomeView(roster: roster, connection: model, router: router)
                    .navigationDestination(for: AppRoute.self) { route in
                        switch route {
                        case .chat(let name):
                            if let bot = roster.bot(named: name) {
                                ChatView(model: ChatModel(bot: bot, connection: model, roster: roster), router: router)
                            }
                        case .botProfile(let name):
                            BotProfileView(
                                model: BotProfileModel(botName: name, services: bots.services, roster: roster, sharer: bots.sharer),
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
                                title: bot?.displayName ?? name,
                                spec: bot?.spec
                            )
                        case .slack(let name):
                            SlackView(model: SlackModel(
                                botName: name,
                                displayName: roster.bot(named: name)?.displayName ?? name,
                                services: bots.services
                            ))
                        }
                    }
            }
            .task { await roster.runLive() }
            .onAppear {
                router.registerShareAsTemplate { name in Task { await bots.sharer.share(botName: name) } }
            }
            .sheet(item: $router.sheet, onDismiss: { createBot = CreateBotModel() }) { sheet in
                switch sheet {
                case .settings:
                    SettingsSheet(model: model) { router.dismissSheet() }
                case .createBot:
                    CreateBotSheet(model: createBot, roster: roster, router: router)
                }
            }
            .fullScreenCover(isPresented: $router.isSearching) {
                SearchHost(roster: roster, router: router)
            }
        case .connecting:
            ProgressView("Connecting")
                .accessibilityIdentifier("connectingIndicator")
        default:
            ConnectionView(model: model)
        }
    }
}
