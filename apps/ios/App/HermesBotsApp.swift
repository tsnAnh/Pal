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
        let router = AppRouter()
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
                .hermesTheme(mode: appearance.mode, botAccent: roster.hero?.accent)
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

    var body: some View {
        switch model.phase {
        case .connected:
            NavigationStack(path: $router.path) {
                RosterView(roster: roster, connection: model) { router.present(.settings) }
                    .navigationDestination(for: AppRoute.self) { route in
                        switch route {
                        case .chat(let name):
                            if let bot = roster.bot(named: name) {
                                ChatView(model: ChatModel(bot: bot, connection: model, roster: roster))
                            }
                        }
                    }
            }
            .task { await roster.runLive() }
            .sheet(item: $router.sheet) { sheet in
                switch sheet {
                case .settings:
                    SettingsSheet(model: model) { router.dismissSheet() }
                }
            }
        case .connecting:
            ProgressView("Connecting")
                .accessibilityIdentifier("connectingIndicator")
        default:
            ConnectionView(model: model)
        }
    }
}
