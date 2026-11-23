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
        VStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                if let spec {
                    BotAvatarView(spec: spec, size: 64, animated: false)
                }
                PalIcon("number", ink: .secondary)
                    .font(.system(size: 14, weight: .bold))
                    .frame(width: 26, height: 26)
                    .background(PalTokens.control, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(PalTokens.borderStrong, lineWidth: PalMetrics.separatorThickness)
                    }
                    .accessibilityHidden(true)
            }
            Text("Add \(model.displayName) to Slack")
                .hermesText(.sheetTitle)
                .foregroundStyle(PalTokens.textPrimary)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("slackTitle")
            Text("DM or @mention \(model.displayName) in Slack. It answers with the same plugins, context and memories as here.")
                .hermesText(.rowTitle)
                .foregroundStyle(PalTokens.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("slackBody")
        }
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
        VStack(spacing: 10) {
            if link.status == nil {
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
        .padding(PalMetrics.screenMargin)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .top) { PalHairline() }
    }
}
