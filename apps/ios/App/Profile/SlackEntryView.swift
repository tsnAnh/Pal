import PalBotProfile
import PalDesign
import SwiftUI

struct SlackEntryView: View {
    let botName: String
    let displayName: String
    let spec: BotAvatarSpec?
    let services: BotsServices
    let source: ChatInstallSource

    @State private var tokensConnected: Bool?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            switch tokensConnected {
            case .none:
                DelayedReveal { ProgressView() }
            case .some(true):
                legacy
            case .some(false):
                SlackSetupScreen(
                    model: SlackSetupModel(botName: botName, displayName: displayName, client: source.client), spec: spec,
                    events: source.events, close: { dismiss() }, advanced: { legacy }
                )
            }
        }
        .environment(\.sheetChromeHostedInNavigation, true)
        .task {
            guard tokensConnected == nil else { return }
            let status = try? await services.slack.status(profile: botName)
            tokensConnected = status.map { $0.connection != .notConnected } ?? false
        }
    }

    private var legacy: some View {
        SlackTokensView(model: SlackModel(botName: botName, displayName: displayName, services: services))
    }
}
