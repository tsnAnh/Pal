import PalBotProfile
import PalConnect
import PalDesign
import SwiftUI

struct SlackTokensView: View {
    @State private var model: SlackModel
    @Environment(\.hermesTheme) private var theme

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
        if let notice = model.notice {
            Text(notice)
                .hermesText(.rowSubtitle)
                .foregroundStyle(PalTokens.textSecondary)
                .accessibilityIdentifier("slackNotice")
        }
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
                        .strokeBorder(
                            shape.isValid ? PalTokens.borderStrong : (shape == .empty ? Color.clear : Color(theme.palette.destructive)),
                            lineWidth: 1.5
                        )
                }
            if showsShape, let message = shape.message(label: field.label) {
                Text(message)
                    .hermesText(.rowSubtitle)
                    .foregroundStyle(shape.isValid ? PalTokens.textSecondary : Color(theme.palette.destructive))
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
            if model.checkFailed {
                SetupButton(title: String(localized: "Retry"), fillsWidth: true, identifier: "slackRetryButton") {
                    Task { await model.recheck() }
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
        case .connected, .starting, .failed:
            EmptyView()
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
