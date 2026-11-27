import PalBotProfile
import PalConnect
import PalDesign
import PalProtocol
import SwiftUI

struct SlackSetupScreen<Advanced: View>: View {
    @State private var model: SlackSetupModel
    let spec: BotAvatarSpec?
    let events: @Sendable () -> AsyncStream<ChatInstallChangedPayload>
    let close: () -> Void
    @ViewBuilder let advanced: () -> Advanced

    @Environment(\.scenePhase) private var scenePhase

    init(
        model: SlackSetupModel, spec: BotAvatarSpec?, events: @escaping @Sendable () -> AsyncStream<ChatInstallChangedPayload>,
        close: @escaping () -> Void, @ViewBuilder advanced: @escaping () -> Advanced
    ) {
        _model = State(initialValue: model)
        self.spec = spec
        self.events = events
        self.close = close
        self.advanced = advanced
    }

    var body: some View {
        content
            .background(PalTokens.content)
            .task {
                await model.load()
                for await payload in events() { await model.receive(payload) }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await model.refresh() } }
            }
            .onChange(of: model.flow.engine.isFinished) { _, isFinished in
                if isFinished { model.completeFlow() }
            }
            #if os(macOS)
            .navigationBarBackButtonHidden(true)
            #endif
    }

    @ViewBuilder
    private var content: some View {
        switch model.stage {
        case .loading:
            DelayedReveal { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityIdentifier("slackSetupLoading") }
        case .flow:
            StepFlowView(
                model: model.flow, title: String(localized: "Add \(model.displayName) to Slack"),
                savedNote: String(localized: "Saved on your Pal. Mac and iPhone show the same step."), close: close
            ) { step in accessory(step) }
            .header(SlackHeader(
                spec: spec, title: SlackHeader.title(name: model.displayName, finished: model.flow.engine.isFinished),
                value: SlackHeader.value(name: model.displayName, finished: model.flow.engine.isFinished)
            ).padding(PalMetrics.screenMargin))
        case .settings:
            SlackSettingsView(model: model, close: close)
        case .linked:
            advanced()
        case .status(let status):
            statusScreen(status)
        }
    }

    private func statusScreen(_ status: SetupStatus) -> some View {
        SetupChrome(title: String(localized: "Add \(model.displayName) to Slack"), accessibilityIdentifier: "slackSetupFrame", close: close) {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                StatusBlock(status: status, identifierPrefix: "slackSetupStatus") {
                    if status.kind == .forbidden { close() } else { Task { await model.load() } }
                }
                if status.kind == .gatewayOutdated {
                    NavigationLink { advanced() } label: {
                        Text("Advanced: paste tokens").foregroundStyle(PalTokens.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, PalMetrics.screenMargin)
                    .accessibilityIdentifier("slackSetupAdvanced")
                }
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private func accessory(_ step: FlowStep) -> some View {
        switch step.id {
        case SlackSetupPlan.introID:
            SlackIntroCard(name: model.displayName)
            NavigationLink { advanced() } label: {
                Text("Advanced: paste tokens").foregroundStyle(PalTokens.textSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("slackSetupAdvanced")
        case SlackSetupPlan.allowID:
            SlackAdminMessage(name: model.displayName)
        case SlackSetupPlan.ownerID:
            Text("In Slack, open your profile, choose More, then Copy member ID.")
                .hermesText(.rowSubtitle)
                .foregroundStyle(PalTokens.textTertiary)
                .accessibilityIdentifier("slackOwnerHelp")
        case SlackSetupPlan.channelsID:
            SlackChannelsView(chat: model.chat, name: model.displayName)
        case SlackSetupPlan.manualID(.setIcon):
            SlackAvatarExport(spec: spec, name: model.displayName)
        case SlackSetupPlan.manualID(.gatewayRedirect):
            if let address = model.chat.state?.nextAction.copyText {
                StepCopyCard(label: String(localized: "Return address"), value: address, identifier: "slackReturnAddress")
            }
        default:
            EmptyView()
        }
    }
}

struct SlackCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PalTokens.elevated, in: RoundedRectangle(cornerRadius: PalMetrics.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: PalMetrics.cardRadius, style: .continuous)
                    .strokeBorder(PalTokens.panelBorder, lineWidth: PalMetrics.separatorThickness)
            }
    }
}

struct SlackIntroCard: View {
    let name: String

    var body: some View {
        SlackCard {
            row(String(localized: "You do"), String(localized: "Copy two codes from Slack · click Allow · pick channels"))
            PalHairline()
            row(String(localized: "\(name) does"), String(localized: "Creates the Slack app with its name and picture"))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("slackIntroCard")
    }

    private func row(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: PalMetrics.rowTextSpacing) {
            Text(title).hermesText(.rowTitle).fontWeight(.semibold).foregroundStyle(PalTokens.textPrimary)
            Text(detail).hermesText(.rowSubtitle).foregroundStyle(PalTokens.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(PalMetrics.screenMargin)
    }
}

struct SlackAdminMessage: View {
    let name: String

    @State private var copied = false

    private static func message(for name: String) -> String {
        let intro = String(localized: "Hi! I'd like to add my assistant \(name) to our Slack.")
        let detail = String(localized: "It's an app that only I can chat with, in the channels I invite it to.")
        let ask = String(localized: "Could you approve the \"\(name)\" app request? Thanks!")
        return "\(intro) \(detail) \(ask)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("If your workspace needs an admin to approve new apps, send them a message.")
                .hermesText(.rowSubtitle)
                .foregroundStyle(PalTokens.textTertiary)
            SetupButton(
                title: copied ? String(localized: "Copied") : String(localized: "Copy a message for my admin"), identifier: "slackCopyAdminMessage"
            ) {
                Pasteboard.string = Self.message(for: name)
                copied = true
            }
        }
    }
}

struct SlackAvatarExport: View {
    let spec: BotAvatarSpec?
    let name: String

    @State private var saved = false

    var body: some View {
        if let spec {
            VStack(alignment: .leading, spacing: 8) {
                SetupButton(title: ChatAvatarExport.actionTitle, identifier: "slackSaveAvatar") {
                    Task {
                        guard let image = ChatAvatarExport.render(spec: spec) else { return }
                        saved = await ChatAvatarExport.deliver(image, name: name)
                    }
                }
                if saved {
                    Text(ChatAvatarExport.explanation)
                        .hermesText(.rowSubtitle)
                        .foregroundStyle(PalTokens.textTertiary)
                        .accessibilityIdentifier("slackAvatarSaved")
                }
            }
        }
    }
}
