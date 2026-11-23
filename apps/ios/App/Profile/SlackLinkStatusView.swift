import PalConnect
import PalDesign
import SwiftUI

struct SlackLinkStatusView: View {
    let model: SlackModel
    let link: SlackLinkProgress
    let spec: BotAvatarSpec?
    let close: () -> Void

    @Environment(\.hermesTheme) private var theme

    private var layout: StepFlowLayout {
        #if os(macOS)
        .stepper
        #else
        .stacked
        #endif
    }

    var body: some View {
        SetupChrome(
            title: String(localized: "Slack"), progress: link.engine, accessibilityIdentifier: "slackSetupFrame", close: close
        ) {
            VStack(spacing: 0) {
                StepFlowSegments(engine: link.engine, layout: layout)
                ScrollView {
                    VStack(spacing: PalMetrics.screenMargin) {
                        header
                        statusArea
                    }
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
                    .padding(PalMetrics.screenMargin)
                }
                .scrollBounceBehavior(.basedOnSize)
                footer
            }
        }
    }

    private var header: some View {
        let finished = link.phase == .connected
        return SlackHeader(
            spec: spec, title: SlackHeader.title(name: model.displayName, finished: finished),
            value: SlackHeader.value(name: model.displayName, finished: finished)
        )
    }

    @ViewBuilder
    private var statusArea: some View {
        if let status = link.status {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    PalIcon(status.symbol, ink: .destructive).accessibilityHidden(true)
                    Text(status.title)
                        .hermesText(.rowTitle)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color(theme.palette.destructive))
                        .accessibilityIdentifier(link.phase == .stalled ? "slackStatusStalled" : "slackStatusFailed")
                }
                Text(status.reason)
                    .hermesText(.rowSubtitle)
                    .foregroundStyle(PalTokens.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("slackFailureReason")
                notice
            }
            .padding(PalMetrics.screenMargin)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PalTokens.chipFill, in: RoundedRectangle(cornerRadius: PalMetrics.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: PalMetrics.cardRadius, style: .continuous)
                    .strokeBorder(Color(theme.palette.destructive), lineWidth: PalMetrics.separatorThickness)
            }
            .accessibilityElement(children: .combine)
        } else if link.phase == .connected {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    PalIcon("checkmark", ink: .success).accessibilityHidden(true)
                    Text("Connected")
                        .hermesText(.rowTitle)
                        .fontWeight(.semibold)
                        .foregroundStyle(PalTokens.textPrimary)
                        .accessibilityIdentifier("slackStatusConnected")
                }
                notice
            }
            .padding(PalMetrics.screenMargin)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PalTokens.chipFill, in: RoundedRectangle(cornerRadius: PalMetrics.cardRadius, style: .continuous))
            .accessibilityElement(children: .combine)
        } else {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Starting Slack for \(model.displayName)…")
                    .hermesText(.rowSubtitle)
                    .foregroundStyle(PalTokens.textSecondary)
                    .accessibilityIdentifier("slackStatusStarting")
            }
            .padding(PalMetrics.screenMargin)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PalTokens.chipFill, in: RoundedRectangle(cornerRadius: PalMetrics.cardRadius, style: .continuous))
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private var notice: some View {
        if let notice = model.notice {
            Text(notice)
                .hermesText(.rowSubtitle)
                .foregroundStyle(PalTokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("slackNotice")
        }
    }

    private var footer: some View {
        VStack(spacing: SetupFooterMetrics.phone.buttonSpacing) {
            if link.phase == .connected {
                SetupButton(title: String(localized: "Done"), kind: .primary, fillsWidth: true, identifier: "slackDoneButton") { close() }
                    .keyboardShortcut(.defaultAction)
                if model.checkFailed {
                    SetupButton(title: String(localized: "Retry"), fillsWidth: true, identifier: "slackRetryButton") {
                        Task { await model.recheck() }
                    }
                }
                SetupButton(title: String(localized: "Update tokens"), fillsWidth: true, identifier: "slackUpdateTokensButton") {
                    model.beginUpdateTokens()
                }
                SetupButton(title: String(localized: "Disconnect"), fillsWidth: true, identifier: "slackDisconnectButton") {
                    model.confirmsDisconnect = true
                }
            } else if link.status == nil {
                SetupButton(title: String(localized: "Working…"), kind: .primary, isBusy: true, fillsWidth: true, identifier: "slackBusy") {}
            } else {
                SetupButton(title: String(localized: "Retry"), kind: .primary, fillsWidth: true, identifier: "slackRetryButton") {
                    Task { await model.recheck() }
                }
                if model.showsUpdateTokens {
                    SetupButton(title: String(localized: "Use tokens instead"), fillsWidth: true, identifier: "slackUpdateTokensButton") {
                        model.beginUpdateTokens()
                    }
                }
            }
        }
        .setupFooter(fillsWidth: true)
    }
}
