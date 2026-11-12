import PalBotProfile
import PalDesign
import SwiftUI

struct BotModelsScreen: View {
    let hub: SettingsHub
    let back: () -> Void

    @State private var model: BotModelsOverviewModel

    init(hub: SettingsHub, back: @escaping () -> Void) {
        self.hub = hub
        self.back = back
        let connection = hub.connection
        let gateway = BotsGateway { method, params in try await connection.rpc(method, params) }
        _model = State(initialValue: BotModelsOverviewModel(client: BotModelsOverviewClient(gateway: gateway)))
    }

    var body: some View {
        SettingsPage(title: "Bot models", identifier: "botModelsScreen", back: back) {
            content
        }
        .task { await model.load() }
        .refreshable { await model.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            GroupedCard(accessibilityIdentifier: "botModelsLoading") {
                LoadingRow(title: "Bot models", identifier: "botModelsLoadingRow")
            }
        case .failed:
            FailureCard(message: "Couldn't load your bots' models.", identifier: "botModelsFailure") {
                Task { await model.load() }
            }
        case .ready:
            ForEach(model.rows) { row in
                BotModelsRowCard(row: row, bot: hub.roster.bot(named: row.name))
            }
            CardFootnote(
                "Chat is the model and reasoning effort each bot's own conversations use. Cloud sessions are chosen when each one starts, and Pal doesn't have that setting yet. Pull to refresh.",
                accessibilityIdentifier: "botModelsFootnote")
        }
    }
}

private struct BotModelsRowCard: View {
    let row: BotModelsRow
    let bot: BotRow?

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: PalMetrics.captionToCardGap) {
            header
            GroupedCard(accessibilityIdentifier: "botModels-\(row.name)") {
                SettingsRow.value(
                    String(localized: "Chat model"), value: row.chat.modelText,
                    accessibilityIdentifier: "botModels-\(row.name)-chatModel")
                SettingsRow.value(
                    String(localized: "Chat effort"), value: row.chat.effortText,
                    accessibilityIdentifier: "botModels-\(row.name)-chatEffort")
                SettingsRow.value(
                    String(localized: "Cloud model"), value: row.cloud?.modelText ?? ReasoningEffort.unknown,
                    accessibilityIdentifier: "botModels-\(row.name)-cloudModel")
                SettingsRow.value(
                    String(localized: "Cloud effort"), value: row.cloud?.cloudEffortText ?? ReasoningEffort.unknown,
                    accessibilityIdentifier: "botModels-\(row.name)-cloudEffort")
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let bot {
                BotAvatarView(spec: bot.spec, size: 28, mood: .idle)
                    .frame(width: 28, height: 28)
            }
            Text(row.displayName)
                .hermesText(.rowSubtitle)
                .foregroundStyle(Color(theme.palette.textSecondary))
        }
        .padding(.horizontal, PalMetrics.screenMargin + PalMetrics.rowInset - 3)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}
