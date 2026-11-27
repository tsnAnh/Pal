import PalBotProfile
import PalConnect
import PalDesign
import SwiftUI

struct DiscordEntryView: View {
    let botName: String
    let displayName: String
    let spec: BotAvatarSpec?
    let services: BotsServices
    let source: ChatInstallSource

    @Environment(\.dismiss) private var dismiss

    private func makeModel() -> DiscordSetupModel {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains(ScriptedDiscordSetup.argument) else {
            return DiscordSetupModel(
                displayName: displayName,
                gateway: DiscordSetupLiveGateway(service: services.ownerConnectService(), client: source.client, spec: spec)
            )
        }
        return DiscordSetupModel(
            displayName: displayName,
            gateway: ScriptedDiscordSetup(
                appReady: arguments.contains(ScriptedDiscordSetup.appReadyArgument),
                needsOwner: arguments.contains(ScriptedDiscordSetup.needsOwnerArgument),
                offline: arguments.contains(ScriptedDiscordSetup.offlineArgument),
                muted: arguments.contains(ScriptedDiscordSetup.mutedArgument), channel: botName
            ),
            timing: ScriptedDiscordSetup.timing
        )
    }

    var body: some View {
        ModelHost {
            makeModel()
        } content: {
            DiscordSetupScreen(model: $0, close: { dismiss() })
        }
        .environment(\.sheetChromeHostedInNavigation, true)
    }
}

struct DiscordSetupScreen: View {
    @State private var model: DiscordSetupModel
    let close: () -> Void

    init(model: DiscordSetupModel, close: @escaping () -> Void) {
        _model = State(initialValue: model)
        self.close = close
    }

    private var title: String { String(localized: "Add \(model.displayName) to Discord") }

    var body: some View {
        content
            .background(PalTokens.content)
            .task { await model.load() }
            #if os(macOS)
            .navigationBarBackButtonHidden(true)
            #endif
    }

    @ViewBuilder
    private var content: some View {
        switch model.stage {
        case .loading:
            DelayedReveal { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityIdentifier("discordSetupLoading") }
        case .flow:
            StepFlowView(model: model.flow, title: title, close: close) { step in accessory(step) }
        case .status(let status):
            statusPage(status, identifierPrefix: "discordSetupStatus") { Task { await model.load() } }
        case .notConnected(let status):
            statusPage(
                status, identifierPrefix: "discordOffline", isBusy: model.isReconnecting, warnings: model.channelWarnings
            ) { Task { await model.reconnect() } }
        }
    }

    private func statusPage(
        _ status: SetupStatus, identifierPrefix: String, isBusy: Bool = false, warnings: [String] = [], perform: @escaping () -> Void
    ) -> some View {
        SetupChrome(title: title, accessibilityIdentifier: "discordSetupFrame", close: close) {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                StatusBlock(status: status, isBusy: isBusy, identifierPrefix: identifierPrefix, perform: perform)
                if !warnings.isEmpty {
                    DiscordChannelWarnings(sentences: warnings)
                        .padding(.top, PalMetrics.captionToCardGap)
                        .padding(.horizontal, PalMetrics.screenMargin)
                }
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private func accessory(_ step: FlowStep) -> some View {
        if step.id == DiscordSetupPlan.doneID {
            DiscordChannelWarnings(sentences: model.channelWarnings)
            SetupButton(title: String(localized: "Reconnect"), isBusy: model.isReconnecting, identifier: "discordReconnect") {
                Task { await model.reconnect() }
            }
            if let url = model.installed.flatMap(DiscordSetupPlan.channelURL) {
                SetupButton(title: String(localized: "Open in Discord"), identifier: "discordOpen") { ExternalLink.open(url) }
            }
        }
    }
}

private struct DiscordChannelWarnings: View {
    let sentences: [String]

    var body: some View {
        if !sentences.isEmpty {
            VStack(spacing: PalMetrics.rowTextSpacing) {
                ForEach(Array(sentences.enumerated()), id: \.offset) { _, sentence in
                    Text(sentence)
                        .hermesText(.rowSubtitle)
                        .foregroundStyle(PalTokens.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("discordChannelWarning")
                }
            }
            .frame(maxWidth: 420)
        }
    }
}
