import PalBotProfile
import PalDesign
import PalProtocol
import SwiftUI

struct SlackChannelsScreen: View {
    let model: SlackSetupModel
    let close: () -> Void

    @State private var search = ""
    @State private var leaving: ChatSpaceRow?

    private var chat: ChatInstallModel { model.chat }
    private var name: String { model.displayName }

    private var matching: [ChatSpaceRow] {
        chat.spaces.filter { search.isEmpty || $0.space.name.localizedCaseInsensitiveContains(search) }
    }

    private var joined: [ChatSpaceRow] {
        matching.filter { $0.status == .live || $0.status == .joining || ($0.status == .needsInvite && $0.invite != nil) }
    }

    private var available: [ChatSpaceRow] {
        matching.filter { row in !joined.contains { $0.id == row.id } }
    }

    var body: some View {
        SetupChrome(title: channelsTitle, accessibilityIdentifier: "slackChannelsScreen", close: close) {
            ScrollView {
                VStack(alignment: .leading, spacing: PalMetrics.screenMargin) {
                    searchField
                    content
                }
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(PalMetrics.screenMargin)
            }
            .scrollIndicators(.hidden)
        }
        .task { await chat.refreshSpaces() }
        .macConfirm(item: $leaving) { row in
            MacDialogContent(
                String(localized: "Leave #\(row.space.name)?"),
                message: String(localized: "\(name) stops answering there. You can add it back any time."),
                actions: [
                    MacDialogAction(String(localized: "Leave"), role: .destructive, identifier: "slackLeaveConfirm") {
                        Task { await model.leave(row.id) }
                    },
                    MacDialogAction(String(localized: "Cancel"), role: .cancel),
                ]
            )
        }
    }

    private var channelsTitle: String {
        #if os(macOS)
        String(localized: "\(name)'s channels")
        #else
        String(localized: "Channels")
        #endif
    }

    private var searchField: some View {
        ClearGlassSearchField(
            text: $search, prompt: String(localized: "Search channels"), accessibilityLabel: String(localized: "Search channels"),
            accessibilityIdentifier: "slackChannelSearch", height: 44, fontSize: 15
        )
    }

    @ViewBuilder
    private var content: some View {
        switch chat.spacesPhase {
        case .loading:
            SlackCard {
                ForEach(0..<4, id: \.self) { index in
                    if index > 0 { PalHairline() }
                    HStack(spacing: 12) {
                        Capsule().fill(PalTokens.control).frame(width: 16, height: 16)
                        Capsule().fill(PalTokens.control).frame(width: 160, height: 12)
                        Spacer(minLength: 0)
                    }
                    .padding(PalMetrics.screenMargin)
                }
            }
            .accessibilityIdentifier("slackChannelsLoading")
        case .failed:
            failed
        case .loaded:
            loaded
        }
    }

    private var failed: some View {
        SlackCard {
            VStack(spacing: 10) {
                PalIcon("number", ink: .tertiary).font(.system(size: 28, weight: .light)).accessibilityHidden(true)
                Text("Couldn't load channels from Slack").hermesText(.rowTitle).foregroundStyle(PalTokens.textPrimary)
                Text("Check your connection and try again. \(name) stays in the channels it's already in.")
                    .hermesText(.rowSubtitle)
                    .foregroundStyle(PalTokens.textTertiary)
                    .multilineTextAlignment(.center)
                Button { Task { await chat.refreshSpaces() } } label: { Label("Try again", palIcon: "arrow.clockwise") }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("slackChannelsRetry")
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(PalMetrics.screenMargin * 1.5)
        }
        .accessibilityIdentifier("slackChannelsFailed")
    }

    @ViewBuilder
    private var loaded: some View {
        if joined.isEmpty, search.isEmpty {
            SlackCard {
                VStack(spacing: 6) {
                    Text("\(name) isn't in any channels yet").hermesText(.rowTitle).foregroundStyle(PalTokens.textPrimary)
                    Text("Pick one below, or type /invite @\(name) in any Slack channel. Direct messages work either way.")
                        .hermesText(.rowSubtitle)
                        .foregroundStyle(PalTokens.textTertiary)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(PalMetrics.screenMargin * 1.5)
            }
            .accessibilityIdentifier("slackChannelsEmpty")
        } else if !joined.isEmpty {
            SlackGroup(
                caption: String(localized: "\(name) is in"),
                footer: String(localized: "In channels, \(name) replies when someone writes @\(name).")
                    + " " + String(localized: "In threads it keeps chatting without a tag. Direct messages always reach it."),
                identifier: "slackChannelsJoined"
            ) {
                ForEach(Array(joined.enumerated()), id: \.element.id) { offset, row in
                    if offset > 0 { PalHairline() }
                    joinedRow(row)
                }
            }
        }
        ForEach(joined.filter { $0.invite != nil }) { row in invite(row) }
        if !available.isEmpty {
            SlackGroup(caption: String(localized: "More channels"), footer: nil, identifier: "slackChannelsMore") {
                ForEach(Array(available.enumerated()), id: \.element.id) { offset, row in
                    if offset > 0 { PalHairline() }
                    availableRow(row)
                }
            }
        }
        SetupQuietButton(title: String(localized: "Check again"), identifier: "slackRefreshChannels") {
            Task { await chat.refreshSpaces() }
        }
    }

    @ViewBuilder
    private func joinedRow(_ row: ChatSpaceRow) -> some View {
        #if os(iOS)
        if row.status == .live {
            SwipeActionRow(actionTitle: String(localized: "Leave"), accessibilityIdentifier: "slackChannelSwipe-\(row.id)") {
                leaving = row
            } content: { channelRow(row) { EmptyView() } }
        } else {
            channelRow(row) { EmptyView() }
        }
        #else
        channelRow(row) {
            if row.status == .live {
                Menu {
                    Button(role: .destructive) {
                        leaving = row
                    } label: {
                        Label("Leave #\(row.space.name)", palIcon: "rectangle.portrait.and.arrow.right")
                    }
                    .accessibilityIdentifier("slackChannelLeave-\(row.id)")
                } label: {
                    PalIcon("ellipsis", ink: .secondary).frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel(Text("More for #\(row.space.name)"))
                .accessibilityIdentifier("slackChannelMenu-\(row.id)")
            }
        }
        .contextMenu {
            if row.status == .live {
                Button(role: .destructive) {
                    leaving = row
                } label: {
                    Label("Leave #\(row.space.name)", palIcon: "rectangle.portrait.and.arrow.right")
                }
            }
        }
        #endif
    }

    private func availableRow(_ row: ChatSpaceRow) -> some View {
        channelRow(row) {
            Button("Join") { Task { await chat.join(row.id) } }
                .buttonStyle(.glass)
                .accessibilityIdentifier("slackChannelJoin-\(row.id)")
        }
    }

    private func channelRow<Trailing: View>(_ row: ChatSpaceRow, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            PalIcon(row.space.kind == .private ? "lock" : "number", ink: .secondary).frame(width: 20).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.space.name).hermesText(.rowTitle).foregroundStyle(PalTokens.textPrimary).lineLimit(1)
                status(row)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
        }
        .padding(PalMetrics.screenMargin)
        .frame(minHeight: PalMetrics.rowMinimumHeight)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("slackChannel-\(row.id)")
    }

    @ViewBuilder
    private func status(_ row: ChatSpaceRow) -> some View {
        switch row.status {
        case .live:
            Text("● Live").hermesText(.rowSubtitle).foregroundStyle(Color.green)
        case .joining:
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text("Joining").hermesText(.rowSubtitle).foregroundStyle(PalTokens.textTertiary)
            }
        case .needsInvite:
            Text("Private: invite \(name) there. Copy the message below.")
                .hermesText(.rowSubtitle)
                .foregroundStyle(PalTokens.textTertiary)
        case .available:
            EmptyView()
        }
    }

    @ViewBuilder
    private func invite(_ row: ChatSpaceRow) -> some View {
        if let invite = row.invite {
            VStack(alignment: .leading, spacing: 8) {
                if let text = invite.copyText {
                    StepCopyCard(label: String(localized: "Paste in the private channel"), value: text, identifier: "slackInvite-\(row.id)")
                }
                if let link = invite.link.flatMap(URL.init(string:)) {
                    Button { ExternalLink.open(link) } label: { Label("Open in Slack", palIcon: "arrow.up.right") }
                        .buttonStyle(.glass)
                        .accessibilityIdentifier("slackOpenChannel-\(row.id)")
                }
            }
        }
    }
}
