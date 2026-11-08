import HermesBotProfile
import HermesDesign
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
        .fullScreenCover(
            item: Binding(get: { model.safariURL.map(SlackTarget.init) }, set: { if $0 == nil { model.safariURL = nil } }),
            onDismiss: { model.safariDismissed() }
        ) { target in
            SafariView(url: target.url).ignoresSafeArea()
        }
        .sheet(isPresented: $model.isEnteringTokens, onDismiss: { model.cancelTokenEntry() }) {
            SlackTokenSheet(model: model)
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
            PillButton(String(localized: "Check again"), kind: .accent, size: .large, accessibilityIdentifier: "slackRecheckButton") {
                Task { await model.recheck() }
            }
        case .starting:
            PillButton(String(localized: "Connecting…"), kind: .accent, size: .large, isBusy: true, accessibilityIdentifier: "slackStartingButton") {}
        }
    }

    private func busyTitle(_ activity: SlackModel.Activity) -> String {
        switch activity {
        case .preparing, .checking: String(localized: "Loading")
        case .connecting: String(localized: "Connecting…")
        case .disconnecting: String(localized: "Disconnecting…")
        }
    }
}

private struct SlackTarget: Identifiable {
    let url: URL

    var id: URL { url }
}

private struct SlackTokenSheet: View {
    @Bindable var model: SlackModel

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        SheetChrome(
            title: String(localized: "Slack tokens"),
            accessibilityIdentifier: "slackTokenSheet",
            onLeading: { model.isEnteringTokens = false },
            trailing: {
                PillButton(
                    String(localized: "Connect"),
                    kind: model.canSubmitTokens ? .accent : .dimmed,
                    accessibilityIdentifier: "slackTokenSubmit"
                ) {
                    Task { await model.submitTokens() }
                }
            },
            content: {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("After installing the app in your workspace, copy its two tokens here.")
                            .hermesText(.rowSubtitle)
                            .foregroundStyle(Color(theme.palette.textSecondary))
                            .padding(.horizontal, HermesMetrics.screenMargin + HermesMetrics.rowInset)
                            .padding(.bottom, HermesMetrics.cardGap)
                        SectionCaption(String(localized: "Bot token"), accessibilityIdentifier: "slackBotTokenCaption")
                            .padding(.bottom, HermesMetrics.captionToCardGap)
                        tokenField(String(localized: "xoxb-…"), text: $model.botToken, identifier: "slackBotToken")
                        SectionCaption(String(localized: "App token"), accessibilityIdentifier: "slackAppTokenCaption")
                            .padding(.top, HermesMetrics.cardGap)
                            .padding(.bottom, HermesMetrics.captionToCardGap)
                        tokenField(String(localized: "xapp-…"), text: $model.appToken, identifier: "slackAppToken")
                    }
                    .padding(.bottom, 32)
                }
                .scrollDismissesKeyboard(.interactively)
            }
        )
    }

    private func tokenField(_ prompt: String, text: Binding<String>, identifier: String) -> some View {
        SecureField("", text: text, prompt: Text(prompt))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .textContentType(.oneTimeCode)
            .padding(.horizontal, HermesMetrics.rowInset)
            .frame(height: HermesMetrics.rowMinimumHeight)
            .background(Color(theme.palette.groupedCard), in: RoundedRectangle(cornerRadius: HermesMetrics.cardRadius, style: .continuous))
            .padding(.horizontal, HermesMetrics.screenMargin)
            .accessibilityLabel(Text(prompt))
            .accessibilityIdentifier(identifier)
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
