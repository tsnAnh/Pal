import PalBotProfile
import PalDesign
import SwiftUI

struct SlackView: View {
    @State private var model: SlackModel

    @Environment(\.hermesTheme) private var theme

    init(model: SlackModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                logoTile
                Text("Bring \(model.displayName) to Slack")
                    .font(.system(size: SlackMetrics.titleSize, weight: .medium))
                    .foregroundStyle(Color(theme.palette.textPrimary))
                    .multilineTextAlignment(.center)
                    .padding(.top, SlackMetrics.logoToTitle)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("slackTitle")
                Text("Uses your Slack connection")
                    .hermesText(.rowTitle)
                    .foregroundStyle(Color(theme.palette.textSecondary))
                    .padding(.top, 6)
                    .accessibilityIdentifier("slackSubtitle")
                Text("You can DM or @mention \(model.displayName) in Slack. It'll respond with the same plugins, context, and memories it uses here.")
                    .hermesText(.rowTitle)
                    .foregroundStyle(Color(theme.palette.textSecondary))
                    .multilineTextAlignment(.center)
                    .padding(.top, SlackMetrics.subtitleToBody)
                    .accessibilityIdentifier("slackBody")
                status
            }
            .padding(.horizontal, SlackMetrics.horizontalPadding)
            .padding(.top, SlackMetrics.topPadding)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Color(theme.palette.sheetBackground).ignoresSafeArea())
        .accessibilityIdentifier("slackScreen")
        .toolbarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) { action }
        .task { await model.load() }
        .onDisappear { model.stop() }
        .sheet(isPresented: $model.isEnteringTokens, onDismiss: { model.cancelTokenEntry() }) {
            SlackTokenSheet(model: model)
                .macSheetFrame()
        }
        .confirmationDialog(
            Text("Disconnect Slack?"),
            isPresented: $model.confirmsDisconnect,
            titleVisibility: .visible
        ) {
            Button("Disconnect", role: .destructive) { Task { await model.disconnect() } }
                .accessibilityIdentifier("slackDisconnectConfirm")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(model.displayName) stops responding in Slack.")
        }
    }

    private var logoTile: some View {
        RoundedRectangle(cornerRadius: SlackMetrics.tileRadius, style: .continuous)
            .fill(Color.white)
            .frame(width: SlackMetrics.tileSize, height: SlackMetrics.tileSize)
            .overlay { SlackMark().frame(width: SlackMetrics.markSize, height: SlackMetrics.markSize) }
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var status: some View {
        VStack(spacing: 10) {
            switch model.connection {
            case .connected:
                statusLine(String(localized: "Connected"), systemImage: "checkmark.circle.fill", identifier: "slackStatusConnected")
            case .starting:
                statusLine(String(localized: "Connecting…"), systemImage: "ellipsis.circle", identifier: "slackStatusStarting")
            case .restartNeeded:
                statusLine(String(localized: "Restart needed"), systemImage: "arrow.triangle.2.circlepath", identifier: "slackStatusRestart")
            case .failed:
                statusLine(String(localized: "Couldn't connect"), systemImage: "exclamationmark.triangle", identifier: "slackStatusFailed")
                if let failure = model.failure {
                    Text(failure.message)
                        .hermesText(.rowSubtitle)
                        .foregroundStyle(Color(theme.palette.textSecondary))
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("slackFailureReason")
                }
            case .notConnected, nil:
                EmptyView()
            }
            if let notice = model.notice {
                Text(notice)
                    .hermesText(.rowSubtitle)
                    .foregroundStyle(Color(theme.palette.textSecondary))
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("slackNotice")
            }
        }
        .padding(.top, SlackMetrics.bodyToStatus)
    }

    private func statusLine(_ text: String, systemImage: String, identifier: String) -> some View {
        Label(text, systemImage: systemImage)
            .hermesText(.rowTitle)
            .foregroundStyle(Color(theme.palette.textPrimary))
            .accessibilityIdentifier(identifier)
    }

    @ViewBuilder
    private var action: some View {
        Group {
            switch model.phase {
            case .loading:
                PillButton(String(localized: "Loading"), kind: .accent, size: .large, isBusy: true, accessibilityIdentifier: "slackLoading") {}
            case .busy(let activity):
                PillButton(busyTitle(activity), kind: .accent, size: .large, isBusy: true, accessibilityIdentifier: "slackBusy") {}
            case .unavailable:
                PillButton(String(localized: "Try again"), kind: .accent, size: .large, accessibilityIdentifier: "slackRetry") {
                    Task { await model.recheck() }
                }
            case .ready(let connection):
                readyAction(connection)
            }
        }
        .padding(.bottom, SlackMetrics.actionBottomPadding)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func readyAction(_ connection: SlackConnection) -> some View {
        VStack(spacing: 8) {
            primaryAction(connection)
            if model.showsUpdateTokens {
                PillButton(String(localized: "Update tokens"), kind: .neutral, size: .large, accessibilityIdentifier: "slackUpdateTokensButton") {
                    model.beginUpdateTokens()
                }
            }
        }
    }

    @ViewBuilder
    private func primaryAction(_ connection: SlackConnection) -> some View {
        switch connection {
        case .notConnected, .failed:
            PillButton(String(localized: "Connect Slack workspace"), kind: .accent, size: .large, accessibilityIdentifier: "slackConnectButton") {
                Task { await model.beginConnect() }
            }
        case .connected:
            PillButton(String(localized: "Disconnect"), kind: .neutral, size: .large, accessibilityIdentifier: "slackDisconnectButton") {
                model.confirmsDisconnect = true
            }
        case .restartNeeded:
            VStack(spacing: 8) {
                PillButton(String(localized: "Restart now"), kind: .accent, size: .large, accessibilityIdentifier: "slackRestartNowButton") {
                    Task { await model.restartNow() }
                }
                PillButton(String(localized: "Check again"), kind: .neutral, size: .large, accessibilityIdentifier: "slackRecheckButton") {
                    Task { await model.recheck() }
                }
            }
        case .starting:
            PillButton(String(localized: "Connecting…"), kind: .accent, size: .large, isBusy: true, accessibilityIdentifier: "slackStartingButton") {}
        }
    }

    private func busyTitle(_ activity: SlackModel.Activity) -> String {
        switch activity {
        case .preparing, .checking: String(localized: "Loading")
        case .connecting: String(localized: "Connecting…")
        case .restarting: String(localized: "Restarting…")
        case .disconnecting: String(localized: "Disconnecting…")
        }
    }
}

private struct SlackTokenSheet: View {
    @Bindable var model: SlackModel

    @Environment(\.hermesTheme) private var theme

    private var isUpdate: Bool { model.tokenEntry == .update }
    private var introText: String {
        isUpdate
            ? String(localized: "Paste the token you want to replace. Leave the other empty to keep the one Hermes already has.")
            : String(localized: "After installing the app in your workspace, copy its two tokens here.")
    }

    private var canSubmit: Bool { isUpdate ? model.canSubmitTokenUpdate : model.canSubmitTokens }

    var body: some View {
        SheetChrome(
            title: isUpdate ? String(localized: "Update Slack tokens") : String(localized: "Slack tokens"),
            accessibilityIdentifier: "slackTokenSheet",
            onLeading: { model.isEnteringTokens = false },
            trailing: {
                PillButton(
                    isUpdate ? String(localized: "Update") : String(localized: "Connect"),
                    kind: canSubmit ? .accent : .dimmed,
                    accessibilityIdentifier: "slackTokenSubmit"
                ) {
                    Task {
                        if isUpdate { await model.submitTokenUpdate() } else { await model.submitTokens() }
                    }
                }
            },
            content: {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(introText)
                            .hermesText(.rowSubtitle)
                            .foregroundStyle(Color(theme.palette.textSecondary))
                            .padding(.horizontal, PalMetrics.screenMargin + PalMetrics.rowInset)
                            .padding(.bottom, PalMetrics.cardGap)
                        SectionCaption(String(localized: "Bot token"), accessibilityIdentifier: "slackBotTokenCaption")
                            .padding(.bottom, PalMetrics.captionToCardGap)
                        tokenField(String(localized: "Bot token"), prompt: String(localized: "xoxb-…"), text: $model.botToken, identifier: "slackBotToken")
                        SectionCaption(String(localized: "App token"), accessibilityIdentifier: "slackAppTokenCaption")
                            .padding(.top, PalMetrics.cardGap)
                            .padding(.bottom, PalMetrics.captionToCardGap)
                        tokenField(String(localized: "App token"), prompt: String(localized: "xapp-…"), text: $model.appToken, identifier: "slackAppToken")
                    }
                    .padding(.bottom, 32)
                }
                .scrollDismissesKeyboard(.interactively)
            }
        )
    }

    private func tokenField(_ label: String, prompt: String, text: Binding<String>, identifier: String) -> some View {
        SecretField(label, prompt: prompt, text: text, identifier: identifier)
            .padding(.horizontal, PalMetrics.rowInset)
            .frame(height: PalMetrics.rowMinimumHeight)
            .background(Color(theme.palette.groupedCard), in: RoundedRectangle(cornerRadius: PalMetrics.cardRadius, style: .continuous))
            .padding(.horizontal, PalMetrics.screenMargin)
    }
}

enum SlackMetrics {
    static let tileSize: CGFloat = 56
    static let tileRadius: CGFloat = 14
    static let markSize: CGFloat = 28
    static let titleSize: CGFloat = 18
    static let topPadding: CGFloat = 18
    static let logoToTitle: CGFloat = 22
    static let subtitleToBody: CGFloat = 24
    static let bodyToStatus: CGFloat = 28
    static let horizontalPadding: CGFloat = 36
    static let actionBottomPadding: CGFloat = 8
}
