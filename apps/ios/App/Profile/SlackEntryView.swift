import PalBotProfile
import PalDesign
import SwiftUI

struct SlackEntryView: View {
    let botName: String
    let displayName: String
    let spec: BotAvatarSpec?
    let services: BotsServices
    let source: ChatInstallSource
    var closeSheet: (() -> Void)?

    @State private var tokensConnected: Bool?
    @Environment(\.dismiss) private var dismiss

    private var close: () -> Void { closeSheet ?? { dismiss() } }

    var body: some View {
        Group {
            switch tokensConnected {
            case .none:
                DelayedReveal { ProgressView() }
            case .some(true):
                tokenLink
            case .some(false):
                ModelHost {
                    SlackSetupModel(botName: botName, displayName: displayName, spec: spec, client: source.client, members: source.members)
                } content: {
                    SlackSetupScreen(model: $0, spec: spec, events: source.events, close: close, advanced: { tokenLink })
                }
            }
        }
        .environment(\.sheetChromeHostedInNavigation, closeSheet == nil)
        .task {
            guard tokensConnected == nil else { return }
            let status = try? await services.slack.status(profile: botName)
            tokensConnected = status.map { $0.connection != .notConnected } ?? false
        }
    }

    private var tokenLink: some View {
        ModelHost {
            SlackModel(botName: botName, displayName: displayName, services: services)
        } content: {
            SlackLinkView(model: $0, spec: spec, closeSheet: closeSheet, close: close)
        }
    }
}
