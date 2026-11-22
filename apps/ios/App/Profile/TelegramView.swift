import PalBotProfile
import PalDesign
import SwiftUI

struct TelegramView: View {
    @State private var model: TelegramModel

    @Environment(\.hermesTheme) private var theme

    init(model: TelegramModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                logoTile
                Text("Bring \(model.displayName) to Telegram")
                    .font(.system(size: TelegramMetrics.titleSize, weight: .medium))
                    .foregroundStyle(Color(theme.palette.textPrimary))
                    .multilineTextAlignment(.center)
                    .padding(.top, TelegramMetrics.logoToTitle)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("telegramTitle")
                Text("Uses a bot token from @BotFather")
                    .hermesText(.rowTitle)
                    .foregroundStyle(Color(theme.palette.textSecondary))
                    .padding(.top, 6)
                    .accessibilityIdentifier("telegramSubtitle")
                Text("You can message \(model.displayName) in Telegram. It'll respond with the same plugins, context, and memories it uses here.")
                    .hermesText(.rowTitle)
                    .foregroundStyle(Color(theme.palette.textSecondary))
                    .multilineTextAlignment(.center)
                    .padding(.top, TelegramMetrics.subtitleToBody)
                    .accessibilityIdentifier("telegramBody")
                status
            }
            .padding(.horizontal, TelegramMetrics.horizontalPadding)
            .padding(.top, TelegramMetrics.topPadding)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Color(theme.palette.sheetBackground).ignoresSafeArea())
        .accessibilityIdentifier("telegramScreen")
        .toolbarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) { action }
        .task { await model.load() }
        .onDisappear { model.stop() }
        .macSheet(isPresented: $model.isEnteringToken, onDismiss: { model.cancelTokenEntry() }, size: .compact, content: {
            TelegramTokenSheet(model: model)
        })
        .macConfirm(isPresented: $model.confirmsDisconnect) {
            MacDialogContent(
                String(localized: "Disconnect Telegram?"),
                message: String(localized: "\(model.displayName) stops responding in Telegram."),
                actions: [
                    MacDialogAction(String(localized: "Disconnect"), role: .destructive, identifier: "telegramDisconnectConfirm") {
                        Task { await model.disconnect() }
                    },
                    MacDialogAction(String(localized: "Cancel"), role: .cancel),
                ]
            )
        }
    }

    private var logoTile: some View {
        RoundedRectangle(cornerRadius: TelegramMetrics.tileRadius, style: .continuous)
            .fill(Color(theme.palette.groupedCard))
            .frame(width: TelegramMetrics.tileSize, height: TelegramMetrics.tileSize)
            .overlay {
                PalIcon("paperplane.fill")
                    .font(.system(size: TelegramMetrics.markSize))
            }
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var status: some View {
        VStack(spacing: 10) {
            switch model.connection {
            case .connected:
                statusLine(String(localized: "Connected"), symbol: "checkmark.circle.fill", identifier: "telegramStatusConnected")
            case .starting:
                statusLine(String(localized: "Connecting…"), symbol: "ellipsis.circle", identifier: "telegramStatusStarting")
            case .restartNeeded:
                statusLine(String(localized: "Restart needed"), symbol: "arrow.triangle.2.circlepath", identifier: "telegramStatusRestart")
            case .failed:
                statusLine(String(localized: "Couldn't connect"), symbol: "exclamationmark.triangle", identifier: "telegramStatusFailed")
                if let failure = model.failure {
                    secondaryText(failure.message, identifier: "telegramFailureReason")
                }
            case .notConnected, nil:
                EmptyView()
            }
            if model.showsOpenToAnyone {
                secondaryText(
                    String(localized: "No allowed users are set, so anyone who finds this bot can message it. Add allowed users in this bot's settings."),
                    identifier: "telegramOpenAccessNote"
                )
            }
            if let notice = model.notice {
                secondaryText(notice, identifier: "telegramNotice")
            }
        }
        .padding(.top, TelegramMetrics.bodyToStatus)
    }

    private func secondaryText(_ text: String, identifier: String) -> some View {
        Text(text)
            .hermesText(.rowSubtitle)
            .foregroundStyle(Color(theme.palette.textSecondary))
            .multilineTextAlignment(.center)
            .accessibilityIdentifier(identifier)
    }

    private func statusLine(_ text: String, symbol: String, identifier: String) -> some View {
        Label(text, palIcon: symbol)
            .hermesText(.rowTitle)
            .foregroundStyle(Color(theme.palette.textPrimary))
            .accessibilityIdentifier(identifier)
    }

    @ViewBuilder
    private var action: some View {
        Group {
            switch model.phase {
            case .loading:
                DelayedReveal {
                    busyButton(String(localized: "Loading"), identifier: "telegramLoading")
                }
            case .busy(let activity):
                busyButton(busyTitle(activity), identifier: "telegramBusy")
            case .unavailable:
                Button(String(localized: "Try again")) {
                    Task { await model.recheck() }
                }
                .glassButtonStyle(prominent: true)
                .accessibilityIdentifier("telegramRetry")
            case .ready(let connection):
                readyAction(connection)
            }
        }
        .padding(.bottom, TelegramMetrics.actionBottomPadding)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func readyAction(_ connection: TelegramConnection) -> some View {
        VStack(spacing: 8) {
            primaryAction(connection)
            if model.showsUpdateToken {
                Button(String(localized: "Update token")) {
                    model.beginUpdateToken()
                }
                .buttonStyle(.glass)
                .accessibilityIdentifier("telegramUpdateTokenButton")
            }
        }
    }

    @ViewBuilder
    private func primaryAction(_ connection: TelegramConnection) -> some View {
        switch connection {
        case .notConnected:
            Button(String(localized: "Connect")) {
                model.beginConnect()
            }
            .glassButtonStyle(prominent: true)
            .accessibilityIdentifier("telegramConnectButton")
        case .failed, .connected:
            Button(String(localized: "Disconnect")) {
                model.confirmsDisconnect = true
            }
            .buttonStyle(.glass)
            .accessibilityIdentifier("telegramDisconnectButton")
        case .restartNeeded:
            Button(String(localized: "Check again")) {
                Task { await model.recheck() }
            }
            .glassButtonStyle(prominent: true)
            .accessibilityIdentifier("telegramRecheckButton")
        case .starting:
            busyButton(String(localized: "Connecting…"), identifier: "telegramStartingButton")
        }
    }

    private func busyButton(_ title: String, identifier: String) -> some View {
        Button {} label: {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(title)
            }
        }
        .glassButtonStyle(prominent: true)
        .disabled(true)
        .accessibilityIdentifier(identifier)
    }

    private func busyTitle(_ activity: TelegramModel.Activity) -> String {
        switch activity {
        case .checking: String(localized: "Loading")
        case .connecting: String(localized: "Connecting…")
        case .disconnecting: String(localized: "Disconnecting…")
        }
    }
}

private struct TelegramTokenSheet: View {
    @Bindable var model: TelegramModel

    @Environment(\.hermesTheme) private var theme

    private var isUpdate: Bool { model.tokenEntry == .update }

    var body: some View {
        SheetChrome(
            title: isUpdate ? String(localized: "Update Telegram token") : String(localized: "Telegram token"),
            accessibilityIdentifier: "telegramTokenSheet",
            onLeading: { model.isEnteringToken = false },
            trailing: {
                Button(isUpdate ? String(localized: "Update") : String(localized: "Connect")) {
                    Task { await model.submitToken() }
                }
                .glassButtonStyle(prominent: true)
                .disabled(!model.canSubmitToken)
                .accessibilityIdentifier("telegramTokenSubmit")
            },
            content: {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(introText)
                            .hermesText(.rowSubtitle)
                            .foregroundStyle(Color(theme.palette.textSecondary))
                            .padding(.horizontal, PalMetrics.screenMargin + PalMetrics.rowInset)
                            .padding(.bottom, PalMetrics.cardGap)
                        SectionCaption(String(localized: "Bot token"), accessibilityIdentifier: "telegramBotTokenCaption")
                            .padding(.bottom, PalMetrics.captionToCardGap)
                        SecretField(String(localized: "Bot token"), prompt: String(localized: "123456:ABC-DEF…"), text: $model.botToken, identifier: "telegramBotToken")
                            .padding(.horizontal, PalMetrics.rowInset)
                            .frame(height: PalMetrics.rowMinimumHeight)
                            .background(Color(theme.palette.groupedCard), in: RoundedRectangle(cornerRadius: PalMetrics.cardRadius, style: .continuous))
                            .padding(.horizontal, PalMetrics.screenMargin)
                    }
                    .padding(.bottom, 32)
                }
                .scrollDismissesKeyboard(.interactively)
            }
        )
    }

    private var introText: String {
        isUpdate
            ? String(localized: "Paste the new token from @BotFather. It replaces the one Pal has now.")
            : String(localized: "Create a bot with @BotFather in Telegram, then paste its token here.")
    }
}

enum TelegramMetrics {
    static let tileSize: CGFloat = 56
    static let tileRadius: CGFloat = 14
    static let markSize: CGFloat = 26
    static let titleSize: CGFloat = 18
    static let topPadding: CGFloat = 18
    static let logoToTitle: CGFloat = 22
    static let subtitleToBody: CGFloat = 24
    static let bodyToStatus: CGFloat = 28
    static let horizontalPadding: CGFloat = 36
    static let actionBottomPadding: CGFloat = 8
}
