import PalBotProfile
import PalConnect
import PalDesign
import PalProtocol
import SwiftUI

struct SlackSettingsView: View {
    let model: SlackSetupModel
    let spec: BotAvatarSpec?
    let close: () -> Void

    @State private var confirmsDisconnect = false
    @State private var editsChannels = false

    private var chat: ChatInstallModel { model.chat }
    private var name: String { model.displayName }

    var body: some View {
        VStack(spacing: 0) {
            SetupHeader(title: String(localized: "\(name) in Slack"), close: close)
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
                        PalHairline()
                        identity
                    }
                    if editsChannels { SlackChannelsView(chat: chat, name: name) }
                    identityResult
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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("slackSettings")
        .confirmationDialog(Text("Disconnect \(name) from Slack?"), isPresented: $confirmsDisconnect, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) { Task { await model.disconnect() } }
                .accessibilityIdentifier("slackDisconnectConfirm")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(name) leaves every channel and stops answering in Slack.")
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

    private var identity: some View {
        let updated = chat.identityUpdate.map { $0.outcome != .needsManualAvatar } ?? false
        return row(
            String(localized: "Name and picture"),
            updated ? String(localized: "Up to date in Slack") : String(localized: "\(name)'s name and picture in Slack"),
            identifier: "slackSettingsIdentity"
        ) {
            SetupButton(title: String(localized: "Update"), isBusy: chat.isWorking, identifier: "slackUpdateIdentity") {
                Task { await chat.updateIdentity() }
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private var identityResult: some View {
        if let update = chat.identityUpdate, update.outcome == .needsManualAvatar {
            VStack(alignment: .leading, spacing: 8) {
                Text("Add \(name)'s picture").hermesText(.rowTitle).fontWeight(.semibold).foregroundStyle(PalTokens.textPrimary)
                Text("Slack doesn't let apps set their own picture. Save it, open the Slack page, and upload it under Display Information.")
                    .hermesText(.rowSubtitle)
                    .foregroundStyle(PalTokens.textSecondary)
                if let link = update.nextAction.link.flatMap(URL.init(string:)) {
                    SetupButton(title: String(localized: "Open the Slack page"), identifier: "slackIdentityOpenPage") { ExternalLink.open(link) }
                }
                SlackAvatarExport(spec: spec, name: name)
            }
            .accessibilityIdentifier("slackIdentityAvatar")
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
