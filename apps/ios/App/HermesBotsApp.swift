import SwiftUI

@main
struct HermesBotsApp: App {
    @State private var model: ConnectionModel
    @State private var roster: RosterModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let model = ConnectionModel.live()
        _model = State(initialValue: model)
        _roster = State(initialValue: RosterModel(connection: model))
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: model, roster: roster)
                .preferredColorScheme(.dark)
                .task { await model.restore() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await model.restore() } }
                }
        }
    }
}

struct RootView: View {
    let model: ConnectionModel
    let roster: RosterModel

    @State private var showsSettings = false

    var body: some View {
        switch model.phase {
        case .connected:
            NavigationStack {
                RosterView(roster: roster, connection: model) { showsSettings = true }
                    .navigationDestination(for: String.self) { name in
                        if let bot = roster.bot(named: name) {
                            ChatView(model: ChatModel(bot: bot, connection: model, roster: roster))
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
