import PalBotProfile
import PalConnect
import PalDesign
import SwiftUI

struct SlackTokensView: View {
    @State private var model: SlackModel

    init(model: SlackModel) {
        _model = State(initialValue: model)
    }

    private static let botField = SetupField(id: "bot", label: "Bot token", secret: true, prefixes: [SlackTokenUpdate.botPrefix])
    private static let appField = SetupField(id: "app", label: "App token", secret: true, prefixes: [SlackTokenUpdate.appPrefix])

    var body: some View {
        VStack(spacing: 0) {
            if model.phase == .unavailable {
                Spacer(minLength: 0)
                StatusBlock(status: SetupStatus(code: SetupStatusClass.offline.rawValue), identifierPrefix: "slackTokens") {
                    Task { await model.recheck() }
                }
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: PalMetrics.screenMargin) {
                        if model.isEnteringTokens { tokenEntry } else { overview }
                    }
                    .frame(maxWidth: 560, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(PalMetrics.screenMargin)
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollDismissesKeyboard(.interactively)
                footer
            }
        }
        .background(PalTokens.content)
        .navigationTitle(Text("Slack"))
        .toolbarTitleDisplayMode(.inline)
        .accessibilityIdentifier("slackScreen")
        .task { await model.load() }
        .onDisappear { model.stop() }
        .macConfirm(isPresented: $model.confirmsDisconnect) {
            MacDialogContent(
                String(localized: "Disconnect Slack?"),
                message: String(localized: "\(model.displayName) stops responding in Slack."),
                actions: [
                    MacDialogAction(String(localized: "Disconnect"), role: .destructive, identifier: "slackDisconnectConfirm") {
                        Task { await model.disconnect() }
                    },
                    MacDialogAction(String(localized: "Cancel"), role: .cancel),
                ]
            )
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: PalMetrics.screenMargin) {
            Text("Bring \(model.displayName) to Slack")
                .hermesText(.sheetTitle)
                .foregroundStyle(PalTokens.textPrimary)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("slackTitle")
            Text("You can DM or @mention \(model.displayName) in Slack. It'll respond with the same plugins, context, and memories it uses here.")
                .hermesText(.rowTitle)
                .foregroundStyle(PalTokens.textSecondary)
                .accessibilityIdentifier("slackBody")
            status
        }
    }

    @ViewBuilder
    private var status: some View {
        switch model.connection {
        case .connected: statusLine(String(localized: "Connected"), "slackStatusConnected")
        case .starting: statusLine(String(localized: "Connecting…"), "slackStatusStarting")
        case .failed:
            statusLine(String(localized: "Couldn't connect"), "slackStatusFailed")
            if let detail = model.detail {
                Text(detail)
                    .hermesText(.rowSubtitle)
                    .foregroundStyle(PalTokens.textSecondary)
                    .accessibilityIdentifier("slackFailureReason")
            }
        case .notConnected, nil: EmptyView()
        }
        if let notice = model.notice {
            Text(notice)
                .hermesText(.rowSubtitle)
                .foregroundStyle(PalTokens.textSecondary)
                .accessibilityIdentifier("slackNotice")
        }
    }

    private func statusLine(_ text: String, _ identifier: String) -> some View {
        Text(text)
            .hermesText(.rowTitle)
            .fontWeight(.semibold)
            .foregroundStyle(PalTokens.textPrimary)
            .accessibilityIdentifier(identifier)
    }

    private var isUpdate: Bool { model.tokenEntry == .update }

    private var tokenEntry: some View {
        VStack(alignment: .leading, spacing: PalMetrics.screenMargin) {
            Text(isUpdate ? String(localized: "Update Slack tokens") : String(localized: "Slack tokens"))
                .hermesText(.sheetTitle)
                .foregroundStyle(PalTokens.textPrimary)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("slackTokenEntry")
            Text(
                isUpdate
                    ? String(localized: "Paste the token you want to replace. Leave the other empty to keep the one Pal already has.")
                    : String(localized: "After installing the app in your workspace, copy its two tokens here.")
            )
            .hermesText(.rowTitle)
            .foregroundStyle(PalTokens.textSecondary)
            tokenField(Self.botField, text: $model.botToken, identifier: "slackBotToken")
            tokenField(Self.appField, text: $model.appToken, identifier: "slackAppToken")
        }
    }

    private func tokenField(_ field: SetupField, text: Binding<String>, identifier: String) -> some View {
        let shape = field.shape(of: text.wrappedValue)
        let showsShape = !(isUpdate && shape == .empty)
        return VStack(alignment: .leading, spacing: 5) {
            Text(field.label).hermesText(.rowSubtitle).fontWeight(.semibold).foregroundStyle(PalTokens.textSecondary)
            SecretField(field.label, prompt: field.prefixes.first.map { "\($0)…" } ?? "", text: text, identifier: identifier)
                .textFieldStyle(.plain)
                .padding(PalMetrics.screenMargin)
                .background(PalTokens.control, in: RoundedRectangle(cornerRadius: PalMetrics.cardRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: PalMetrics.cardRadius, style: .continuous)
                        .strokeBorder(shape.isValid ? Color.green.opacity(0.5) : (shape == .empty ? Color.clear : Color.red), lineWidth: 1.5)
                }
            if showsShape, let message = shape.message(label: field.label) {
                Text(message)
                    .hermesText(.rowSubtitle)
                    .foregroundStyle(shape.isValid ? Color.green : Color.red)
                    .accessibilityIdentifier("\(identifier)Hint")
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        VStack(spacing: 10) {
            switch model.phase {
            case .loading:
                DelayedReveal { ProgressView().accessibilityIdentifier("slackLoading") }
            case .busy(let activity):
                SetupButton(title: busyTitle(activity), kind: .primary, isBusy: true, fillsWidth: true, identifier: "slackBusy") {}
            case .ready(let connection):
                actions(connection)
            case .unavailable:
                EmptyView()
            }
        }
        .padding(PalMetrics.screenMargin)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .top) { PalHairline() }
    }

    @ViewBuilder
    private func actions(_ connection: SlackConnection) -> some View {
        if model.isEnteringTokens {
            let canSubmit = isUpdate ? model.canSubmitTokenUpdate : model.canSubmitTokens
            SetupButton(
                title: isUpdate ? String(localized: "Update") : String(localized: "Connect"), kind: .primary, fillsWidth: true,
                identifier: "slackTokenSubmit"
            ) {
                Task { if isUpdate { await model.submitTokenUpdate() } else { await model.submitTokens() } }
            }
            .disabled(!canSubmit)
            SetupQuietButton(title: String(localized: "Cancel"), identifier: "slackTokenCancel") { model.cancelTokenEntry() }
        } else {
            primary(connection)
            if model.checkFailed, connection != .failed {
                SetupButton(title: String(localized: "Retry"), fillsWidth: true, identifier: "slackRetryButton") {
                    Task { await model.recheck() }
                }
            }
            if model.showsUpdateTokens {
                SetupButton(title: String(localized: "Update tokens"), fillsWidth: true, identifier: "slackUpdateTokensButton") {
                    model.beginUpdateTokens()
                }
            }
        }
    }

    @ViewBuilder
    private func primary(_ connection: SlackConnection) -> some View {
        switch connection {
        case .notConnected:
            SetupButton(title: String(localized: "Connect Slack workspace"), kind: .primary, fillsWidth: true, identifier: "slackConnectButton") {
                Task { await model.beginConnect() }
            }
        case .failed:
            SetupButton(title: String(localized: "Retry"), kind: .primary, fillsWidth: true, identifier: "slackRetryButton") {
                Task { await model.recheck() }
            }
            SetupButton(title: String(localized: "Connect Slack workspace"), fillsWidth: true, identifier: "slackConnectButton") {
                Task { await model.beginConnect() }
            }
        case .connected:
            SetupButton(title: String(localized: "Disconnect"), fillsWidth: true, identifier: "slackDisconnectButton") {
                model.confirmsDisconnect = true
            }
        case .starting:
            SetupButton(title: String(localized: "Connecting…"), kind: .primary, isBusy: true, fillsWidth: true, identifier: "slackStartingButton") {}
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
