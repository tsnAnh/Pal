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
        .sheet(isPresented: $model.isEnteringToken, onDismiss: { model.cancelTokenEntry() }) {
            TelegramTokenSheet(model: model)
                .macSheetFrame()
        }
        .confirmationDialog(
            Text("Disconnect Telegram?"),
            isPresented: $model.confirmsDisconnect,
            titleVisibility: .visible
        ) {
            Button("Disconnect", role: .destructive) { Task { await model.disconnect() } }
                .accessibilityIdentifier("telegramDisconnectConfirm")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(model.displayName) stops responding in Telegram.")
        }
    }

    private var logoTile: some View {
        RoundedRectangle(cornerRadius: TelegramMetrics.tileRadius, style: .continuous)
            .fill(Color(theme.palette.groupedCard))
            .frame(width: TelegramMetrics.tileSize, height: TelegramMetrics.tileSize)
            .overlay {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: TelegramMetrics.markSize))
                    .foregroundStyle(Color(theme.palette.textPrimary))
            }
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var status: some View {
        VStack(spacing: 10) {
            switch model.connection {
            case .connected:
                statusLine(String(localized: "Connected"), systemImage: "checkmark.circle.fill", identifier: "telegramStatusConnected")
            case .starting:
                statusLine(String(localized: "Connecting…"), systemImage: "ellipsis.circle", identifier: "telegramStatusStarting")
            case .restartNeeded:
                statusLine(String(localized: "Restart needed"), systemImage: "arrow.triangle.2.circlepath", identifier: "telegramStatusRestart")
            case .failed:
                statusLine(String(localized: "Couldn't connect"), systemImage: "exclamationmark.triangle", identifier: "telegramStatusFailed")
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
                PillButton(String(localized: "Loading"), kind: .accent, size: .large, isBusy: true, accessibilityIdentifier: "telegramLoading") {}
            case .busy(let activity):
                PillButton(busyTitle(activity), kind: .accent, size: .large, isBusy: true, accessibilityIdentifier: "telegramBusy") {}
            case .unavailable:
                PillButton(String(localized: "Try again"), kind: .accent, size: .large, accessibilityIdentifier: "telegramRetry") {
                    Task { await model.recheck() }
                }
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
                PillButton(String(localized: "Update token"), kind: .neutral, size: .large, accessibilityIdentifier: "telegramUpdateTokenButton") {
                    model.beginUpdateToken()
                }
            }
        }
    }

    @ViewBuilder
    private func primaryAction(_ connection: TelegramConnection) -> some View {
        switch connection {
        case .notConnected:
            PillButton(String(localized: "Connect"), kind: .accent, size: .large, accessibilityIdentifier: "telegramConnectButton") {
                model.beginConnect()
            }
        case .failed, .connected:
            PillButton(String(localized: "Disconnect"), kind: .neutral, size: .large, accessibilityIdentifier: "telegramDisconnectButton") {
                model.confirmsDisconnect = true
            }
        case .restartNeeded:
            PillButton(String(localized: "Check again"), kind: .accent, size: .large, accessibilityIdentifier: "telegramRecheckButton") {
                Task { await model.recheck() }
            }
        case .starting:
            PillButton(String(localized: "Connecting…"), kind: .accent, size: .large, isBusy: true, accessibilityIdentifier: "telegramStartingButton") {}
        }
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
                PillButton(
                    isUpdate ? String(localized: "Update") : String(localized: "Connect"),
                    kind: model.canSubmitToken ? .accent : .dimmed,
                    accessibilityIdentifier: "telegramTokenSubmit"
                ) {
                    Task { await model.submitToken() }
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
