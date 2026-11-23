import PalBotProfile
import PalConnect
import PalDesign
import PalProtocol
import SwiftUI

struct SlackSettingsView: View {
    let model: SlackSetupModel
    let close: () -> Void

    @State private var confirmsDisconnect = false
    @State private var confirmsReinstall = false
    @State private var showsChannels = false
    @Environment(\.hermesTheme) private var theme

    private var chat: ChatInstallModel { model.chat }
    private var members: ChatMembersModel { model.members }
    private var name: String { model.displayName }
    private var needsReinstall: Bool { chat.snapshot?.installation?.status == .needsReauth }
    private var workspaceName: String { chat.snapshot?.installation?.workspaceName ?? String(localized: "your workspace") }

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
                    if needsReinstall { reinstallBanner }
                    preferences
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
        chrome
            .task { await model.loadMembers() }
            .slackChannelsPresentation(isPresented: $showsChannels) { SlackChannelsScreen(model: model) { showsChannels = false } }
            .macConfirm(isPresented: $confirmsReinstall) {
                MacDialogContent(
                    String(localized: "Reinstall \(name) in Slack?"),
                    message: String(localized: "Pal removes \(name) from Slack first, then walks you through adding it again."),
                    actions: [
                        MacDialogAction(String(localized: "Reinstall"), role: .destructive, identifier: "slackReinstallConfirm") {
                            Task { await model.disconnect() }
                        },
                        MacDialogAction(String(localized: "Cancel"), role: .cancel),
                    ]
                )
            }
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

    @ViewBuilder
    private var chrome: some View {
        #if os(iOS)
        if showsChannels {
            SlackChannelsScreen(model: model) { showsChannels = false }
        } else {
            SetupChrome(title: String(localized: "\(name) in Slack"), accessibilityIdentifier: "slackSettings", close: close) { page }
        }
        #else
        SetupChrome(title: String(localized: "\(name) in Slack"), accessibilityIdentifier: "slackSettings", close: close) { page }
        #endif
    }

    private var workspace: some View {
        row(
            String(localized: "Workspace"), chat.snapshot?.installation?.workspaceName ?? String(localized: "Connected"),
            identifier: "slackSettingsWorkspace"
        ) {
            switch chat.snapshot?.installation?.status {
            case .needsReauth:
                Text("Needs reinstall").hermesText(.rowSubtitle).foregroundStyle(Color(theme.palette.destructive))
            case .active:
                Text("● Live").hermesText(.rowSubtitle).foregroundStyle(Color(theme.palette.workingDot))
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
            SetupQuietButton(title: String(localized: "Change ›"), identifier: "slackChannelsChange") { showsChannels = true }
        }
    }

    private var reinstallBanner: some View {
        SlackCard {
            HStack(alignment: .top, spacing: 12) {
                PalIcon("exclamationmark.triangle", ink: .secondary).foregroundStyle(Color.orange).padding(.top, 2).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(name) lost access to \(workspaceName)").hermesText(.rowTitle).fontWeight(.semibold)
                        .foregroundStyle(PalTokens.textPrimary)
                    Text("Someone removed \(name) from the workspace, or its access changed. Reinstall to bring it back.")
                        .hermesText(.rowSubtitle)
                        .foregroundStyle(PalTokens.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    SetupButton(title: String(localized: "Reinstall in Slack"), kind: .primary, symbol: "arrow.up.right", identifier: "slackReinstall") {
                        confirmsReinstall = true
                    }
                    .padding(.top, 8)
                }
                Spacer(minLength: 0)
            }
            .padding(PalMetrics.screenMargin)
        }
        .accessibilityIdentifier("slackReinstallBanner")
    }

    @ViewBuilder
    private var preferences: some View {
        switch members.phase {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, minHeight: 160).accessibilityIdentifier("slackPreferencesLoading")
        case .failed:
            VStack(spacing: 10) {
                Text("Couldn't load these choices").hermesText(.rowTitle).foregroundStyle(PalTokens.textPrimary)
                Text("Check your connection and try again.").hermesText(.rowSubtitle).foregroundStyle(PalTokens.textTertiary)
                Button { Task { await members.reload() } } label: { Label("Try again", palIcon: "arrow.clockwise") }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("slackPreferencesRetry")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
            .accessibilityIdentifier("slackPreferencesFailed")
        case .ready:
            VStack(alignment: .leading, spacing: PalMetrics.screenMargin) {
                SlackAudienceSection(members: members, name: name, workspace: workspaceName)
                SlackReportSection(members: members, chat: chat, name: name)
                approvals
            }
            .opacity(needsReinstall ? 0.45 : 1)
            .disabled(needsReinstall)
            memberNotice
        }
    }

    private var approvals: some View {
        SlackGroup(
            caption: String(localized: "Approvals"),
            footer: String(localized: "\(name) asks before it does anything someone else requested. Answer in whichever you see first."),
            identifier: "slackApprovals"
        ) {
            HStack(spacing: 12) {
                PalIcon("hand.raised", ink: .secondary).frame(width: 20).accessibilityHidden(true)
                Text("Requests from others").hermesText(.rowTitle).foregroundStyle(PalTokens.textPrimary)
                Spacer(minLength: 8)
                Text("Ask me in Slack and here").hermesText(.rowValue).foregroundStyle(PalTokens.textSecondary).multilineTextAlignment(.trailing)
            }
            .padding(PalMetrics.screenMargin)
            .frame(minHeight: PalMetrics.rowMinimumHeight)
        }
    }

    @ViewBuilder
    private var memberNotice: some View {
        if let notice = members.notice {
            SlackNotice(text: Self.copy(for: notice), identifier: "slackMemberNotice")
        }
    }

    private static func copy(for notice: ChatMembersModel.Notice) -> String {
        switch notice {
        case .changedElsewhere: String(localized: "This changed on another device, so Pal reloaded it. Check the choice and try again.")
        case .offline: String(localized: "Couldn't reach Pal. Check your connection and try again.")
        case .notJoined: String(localized: "That channel isn't one it's in anymore. Pick another.")
        case .notSaved: String(localized: "That didn't go through. Try again.")
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
                    Text("Disconnect").hermesText(.rowTitle).fontWeight(.semibold).foregroundStyle(Color(theme.palette.destructive))
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

extension View {
    @ViewBuilder
    func slackChannelsPresentation<Destination: View>(
        isPresented: Binding<Bool>, @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        #if os(macOS)
        macSheet(isPresented: isPresented, size: .full, content: destination)
        #else
        self
        #endif
    }
}
