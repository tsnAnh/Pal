import PalBotProfile
import PalConnect
import PalDesign
import SwiftUI

struct SlackWizardContext {
    let bots: [CustomConnectorBot]
    let connection: ConnectionModel
    let services: BotsServices

    @MainActor
    init(bots: [CustomConnectorBot], connection: ConnectionModel) {
        self.bots = bots
        self.connection = connection
        services = BotsServices(connection: connection)
    }

    @MainActor
    func slackBots() -> [SlackBot] {
        bots.map { bot in
            SlackBot(name: bot.name, displayName: bot.displayName, client: ChatInstallSource.make(botName: bot.name, connection: connection).client)
        }
    }

    @MainActor
    func entry(for name: String) -> SlackEntryView? {
        guard let bot = bots.first(where: { $0.name == name }) else { return nil }
        return SlackEntryView(
            botName: bot.name, displayName: bot.displayName, spec: bot.spec, services: services,
            source: ChatInstallSource.make(botName: bot.name, connection: connection)
        )
    }
}

struct SlackBotChoice: View {
    let model: SlackBotsModel
    let wizard: SlackWizardContext
    let close: () -> Void

    var body: some View {
        NavigationStack { page }
            .task { await model.load() }
            .iOSOnly { $0.accessibilityIdentifier("slackBotPicker") }
    }

    @ViewBuilder
    private var page: some View {
        #if os(macOS)
        SheetChrome(title: String(localized: "Slack"), accessibilityIdentifier: "slackBotPicker", onLeading: close) {
            content
        }
        #else
        content
            .background(PalTokens.content)
            .navigationTitle(Text("Slack"))
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(role: .close, action: close) }
            }
        #endif
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            DelayedReveal { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        case .failed(let error):
            StatusBlock(status: SetupStatus(chatError: error), identifierPrefix: "slackPicker") {
                Task { await model.load() }
            }
        case .ready:
            List(model.rows) { row in
                NavigationLink {
                    if let entry = wizard.entry(for: row.name) {
                        entry.onDisappear { Task { await model.load() } }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.displayName).hermesText(.rowTitle).foregroundStyle(PalTokens.textPrimary)
                        Text(row.state.detail).hermesText(.rowSubtitle).foregroundStyle(PalTokens.textSecondary)
                    }
                }
                .accessibilityIdentifier("slackBot-\(row.name)")
            }
        }
    }
}
