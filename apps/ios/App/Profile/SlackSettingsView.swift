import PalBotProfile
import PalConnect
import PalDesign
import PalProtocol
import SwiftUI

struct SlackSettingsView: View {
    let model: SlackSetupModel
    let close: () -> Void

    @State private var confirmsDisconnect = false
    @State private var editsChannels = false

    private var chat: ChatInstallModel { model.chat }
    private var name: String { model.displayName }

    private var page: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: PalMetrics.screenMargin) {
                    Text("\(name) is in Slack")
                        .hermesText(.sheetTitle)
                        .foregroundStyle(PalTokens.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("slackSettingsTitle")
                    SlackCard {
                        workspace
                        PalHairline()
                        channels
                    }
                    if editsChannels { SlackChannelsView(chat: chat, name: name) }
                    notice
                    SlackCard { disconnect }
                }
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(PalMetrics.screenMargin)
            }
            .scrollIndicators(.hidden)
            footer
        }
    }

    var body: some View {
        SetupChrome(title: String(localized: "\(name) in Slack"), accessibilityIdentifier: "slackSettings", close: close) { page }
            .macConfirm(isPresented: $confirmsDisconnect) {
                MacDialogContent(
                    String(localized: "Disconnect \(name) from Slack?"),
                    message: String(localized: "\(name) leaves every channel and stops answering in Slack."),
                    actions: [
                        MacDialogAction(String(localized: "Disconnect"), role: .destructive, identifier: "slackDisconnectConfirm") {
                            Task { await model.disconnect() }
                        },
                        MacDialogAction(String(localized: "Cancel"), role: .cancel),
                    ]
                )
            }
    }

    private var workspace: some View {
        row(
            String(localized: "Workspace"), chat.snapshot?.installation?.workspaceName ?? String(localized: "Connected"),
            identifier: "slackSettingsWorkspace"
        ) {
            switch chat.snapshot?.installation?.status {
            case .needsReauth:
                Text("Needs reinstall").hermesText(.rowSubtitle).foregroundStyle(Color.red)
            case .active:
                Text("● Live").hermesText(.rowSubtitle).foregroundStyle(Color.green)
            default:
                EmptyView()
            }
        }
    }

    private var channels: some View {
        let live = chat.spaces.filter { $0.status == .live }.map { "# \($0.space.name)" }
        return row(
            String(localized: "Channels"), live.isEmpty ? String(localized: "No channels yet") : live.joined(separator: ", "),
            identifier: "slackSettingsChannels"
        ) {
            SetupQuietButton(title: String(localized: "Change ›"), identifier: "slackChannelsChange") { editsChannels.toggle() }
        }
    }

    @ViewBuilder
    private var notice: some View {
        if let notice = chat.notice {
            Text(notice == .offline
                ? String(localized: "Couldn't reach Pal. Check your connection and try again.")
                : String(localized: "That didn't go through. Try again."))
                .hermesText(.rowSubtitle)
                .foregroundStyle(PalTokens.textSecondary)
                .accessibilityIdentifier("slackSettingsNotice")
        }
    }

    private var disconnect: some View {
        Button { confirmsDisconnect = true } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Disconnect").hermesText(.rowTitle).fontWeight(.semibold).foregroundStyle(Color.red)
                    Text("Removes \(name) from this workspace").hermesText(.rowSubtitle).foregroundStyle(PalTokens.textTertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(PalMetrics.screenMargin)
            .frame(minHeight: PalMetrics.rowMinimumHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("slackDisconnect")
    }

    private var footer: some View {
        HStack {
            Spacer(minLength: 0)
            SetupButton(title: String(localized: "Done"), kind: .primary, identifier: "slackSettingsDone", action: close)
        }
        .padding(PalMetrics.screenMargin)
        .overlay(alignment: .top) { PalHairline() }
    }

    private func row<Trailing: View>(
        _ title: String, _ detail: String, identifier: String, @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).hermesText(.rowTitle).fontWeight(.semibold).foregroundStyle(PalTokens.textPrimary)
                Text(detail).hermesText(.rowSubtitle).foregroundStyle(PalTokens.textTertiary)
            }
            Spacer(minLength: 0)
            trailing()
        }
        .padding(PalMetrics.screenMargin)
        .frame(minHeight: PalMetrics.rowMinimumHeight)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}
