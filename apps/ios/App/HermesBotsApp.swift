import AppIntents
import HermesClient
import SwiftUI

@main
struct HermesBotsApp: App {
    @State private var model: ConnectionModel
    @State private var roster: RosterModel
    @State private var offers: ReachOfferModel
    @State private var links: BotLinks
    @State private var directory = BotDirectory()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let model = ConnectionModel.live()
        _model = State(initialValue: model)
        let roster = RosterModel(connection: model)
        _roster = State(initialValue: roster)
        _offers = State(initialValue: ReachOfferModel(presence: model.presence) { sessionID in roster.open(sessionID: sessionID) })
        let links = BotLinks(connection: model)
        _links = State(initialValue: links)
        let environment = IntentEnvironment(connection: model, roster: roster, links: links)
        AppDependencyManager.shared.add(dependency: environment)
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: model, roster: roster, links: links)
                .overlay { ReachOfferOverlay(model: offers) }
                .preferredColorScheme(.dark)
                .task { await model.restore() }
                .task { await offers.listen() }
                .onChange(of: roster.bots) { _, bots in
                    Task { await directory.publish(bots) }
                }
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
    @Bindable var roster: RosterModel
    let links: BotLinks

    @State private var showsSettings = false

    var body: some View {
        switch model.phase {
        case .connected:
            NavigationStack(path: $roster.path) {
                RosterView(roster: roster, connection: model) { showsSettings = true }
                    .navigationDestination(for: String.self) { name in
                        if let bot = roster.bot(named: name) {
                            ChatView(model: ChatModel(bot: bot, links: links, roster: roster))
                        }
                    }
            }
            .task { await roster.runLive() }
            .sheet(isPresented: $showsSettings) {
                ConnectionView(model: model) { showsSettings = false }
            }
        case .connecting:
            ProgressView("Connecting")
                .accessibilityIdentifier("connectingIndicator")
        default:
            ConnectionView(model: model, onDone: nil)
        }
    }
}
