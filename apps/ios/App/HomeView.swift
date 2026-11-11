import HermesDesign
import HermesRoster
import SwiftUI

struct HomeView: View {
    @Bindable var roster: RosterModel
    let connection: ConnectionModel
    let router: AppRouter

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.hermesTheme) private var theme
    @Environment(RoomsModel.self) private var rooms

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if !roster.pinned.isEmpty {
                    PinnedHero(roster: roster, router: router)
                        .padding(.top, HermesMetrics.heroTopPadding)
                        .padding(.bottom, HermesMetrics.heroRowSpacing)
                }
                ForEach(roster.rows) { bot in
                    HomeBotLink(bot: bot, roster: roster, router: router)
                }
                if rooms.isAvailable, !rooms.rooms.isEmpty {
                    RoomsHomeSection(rooms: rooms, roster: roster, router: router)
                        .padding(.top, 6)
                }
                if !roster.hiddenBots.isEmpty {
                    HiddenBotsSection(roster: roster, router: router)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 24)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .accessibilityIdentifier("rosterScreen")
        .toolbar {
            ToolbarItem(placement: .leadingBar) {
                Button { router.present(.settings) } label: {
                    UserAvatarView(initial: connection.userInitial, link: roster.link)
                }
                .accessibilityLabel(Text("Account and settings"))
                .accessibilityIdentifier("userAvatarButton")
                .tint(.primary)
            }
            if rooms.canCreate {
                ToolbarItem(placement: .trailingBar) {
                    Button { rooms.showsCreate = true } label: {
                        Image(systemName: "person.2")
                    }
                    .accessibilityLabel(Text("New Group Chat"))
                    .accessibilityIdentifier("createRoomButton")
                    .tint(.primary)
                }
            }
            ToolbarItem(placement: .trailingBar) {
                Button { router.present(.createBot) } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(Text("Create New Bot"))
                .accessibilityIdentifier("createBotButton")
                .tint(.primary)
            }
        }
        .toolbarTitleDisplayMode(.inline)
        .background(Color(theme.palette.canvas))
        .safeAreaBar(edge: .bottom) {
            FloatingSearchLauncher(
                accessibilityLabel: String(localized: "Search"),
                accessibilityIdentifier: "rosterSearchField",
                leadingButton: router.capabilities.contains(.connectApps)
                    ? FloatingSearchBarLeadingButton(
                        systemName: "square.grid.2x2",
                        accessibilityLabel: String(localized: "Connect apps"),
                        accessibilityIdentifier: "connectAppsButton"
                    ) { router.presentConnectApps() }
                    : nil
            ) { router.openSearch() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { roster.nudge() }
        }
        .overlay {
            if roster.isLoaded, roster.bots.isEmpty {
                ContentUnavailableView("No bots yet", systemImage: "face.smiling", description: Text("Bots you create appear here."))
            }
        }
        .botManagementDialogs(roster: roster, router: router)
    }
}

private struct HomeBotLink: View {
    let bot: BotRow
    let roster: RosterModel
    let router: AppRouter

    var body: some View {
        RouteLink(
            value: AppRoute.chat(botName: bot.name),
            isSelected: router.path.first == .chat(botName: bot.name),
            select: { router.openChat(botName: bot.name) }
        ) {
            HomeRow(bot: bot, activity: roster.activity(for: bot.name), mood: roster.avatarMood(for: bot.name))
                .botContextMenu(bot, roster: roster, router: router)
        }
        .buttonStyle(HomeRowButtonStyle(radius: 10))
        .accessibilityIdentifier("botRow-\(bot.name)")
        .accessibilityValue(Text(roster.activity(for: bot.name).accessibilityValue))
    }
}

private struct HomeRowButtonStyle: ButtonStyle {
    let radius: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                configuration.isPressed ? PalTokens.selected : Color.clear,
                in: RoundedRectangle(cornerRadius: radius, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

private struct HiddenBotsSection: View {
    let roster: RosterModel
    let router: AppRouter

    @AppStorage("home.hiddenExpanded") private var expanded = false

    var body: some View {
        VStack(spacing: 0) {
            Button { withAnimation(.snappy(duration: 0.18)) { expanded.toggle() } } label: {
                HStack(spacing: 6) {
                    Text("Hidden Bots")
                        .font(.system(size: 13))
                        .foregroundStyle(PalTokens.textTertiary)
                    Spacer(minLength: 0)
                    Text("\(roster.hiddenBots.count)")
                        .font(.system(size: 13))
                        .foregroundStyle(PalTokens.textTertiary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(PalTokens.textTertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .padding(.horizontal, HermesMetrics.homeRowInset - 8)
                .frame(height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Hidden Bots"))
            .accessibilityValue(Text("\(roster.hiddenBots.count)"))
            .accessibilityHint(Text(expanded ? "Collapses the hidden bots" : "Shows the hidden bots"))
            .accessibilityIdentifier("hiddenBotsHeader")
            if expanded {
                VStack(spacing: 0) {
                    ForEach(roster.hiddenBots) { bot in
                        HomeBotLink(bot: bot, roster: roster, router: router)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("hiddenBotsList")
                .transition(.opacity)
            }
        }
        .padding(.top, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("hiddenBots")
    }
}

enum AdminErrorCopy {
    static func message(_ error: BotAdminError?) -> LocalizedStringKey {
        switch error {
        case .permissionDenied: "This device isn't allowed to change bots."
        case .botNotFound: "That bot no longer exists."
        case .conflict: "Another device changed this bot at the same time. Try again."
        case .invalidName: "Choose a name between 1 and 60 characters."
        default: "Try again in a moment."
        }
    }
}

private struct UserAvatarView: View {
    let initial: String
    let link: GatewayLink

    @Environment(\.hermesTheme) private var theme

    private var presenceColor: Color {
        switch link {
        case .connected: Color(theme.palette.accentBlue)
        case .reconnecting: .orange
        case .offline: Color(theme.palette.textTertiary)
        }
    }

    private var presenceLabel: LocalizedStringKey {
        switch link {
        case .connected: "Connected"
        case .reconnecting: "Reconnecting"
        case .offline: "Offline"
        }
    }

    var body: some View {
        Text(initial)
            .font(.headline)
            .foregroundStyle(Color(theme.palette.textPrimary))
            .overlay(alignment: .bottomTrailing) {
                Circle()
                    .fill(presenceColor)
                    .frame(width: 8, height: 8)
                    .offset(x: 6, y: 4)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityValue(Text(presenceLabel))
    }
}

private struct PinnedHero: View {
    let roster: RosterModel
    let router: AppRouter

    var body: some View {
        ViewThatFits(in: .horizontal) {
            cells.frame(maxWidth: .infinity)
            ScrollView(.horizontal, showsIndicators: false) {
                cells.padding(.horizontal, 8)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pinnedHero")
    }

    private var cells: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(roster.pinned) { bot in
                RouteLink(
                    value: AppRoute.chat(botName: bot.name),
                    isSelected: router.path.first == .chat(botName: bot.name),
                    select: { router.openChat(botName: bot.name) }
                ) {
                    HeroCell(bot: bot, activity: roster.activity(for: bot.name), mood: roster.avatarMood(for: bot.name))
                        .botContextMenu(bot, roster: roster, router: router)
                }
                .buttonStyle(HomeRowButtonStyle(radius: 12))
                .accessibilityIdentifier("botRow-\(bot.name)")
                .accessibilityValue(Text(roster.activity(for: bot.name).accessibilityValue))
            }
        }
    }
}

private struct HeroCell: View {
    let bot: BotRow
    let activity: BotActivity
    let mood: AvatarMood

    @Environment(\.hermesTheme) private var theme

    private var heroLabel: String {
        let base = bot.isPrimary ? "\(bot.displayName), primary bot" : "\(bot.displayName), pinned"
        return bot.isUnread ? "\(base), unread" : base
    }

    var body: some View {
        VStack(spacing: HermesMetrics.heroNameGap) {
            AvatarBadge(
                diameter: HermesMetrics.heroDiameter,
                showsPrimaryBadge: bot.isPrimary,
                accessibilityIdentifier: "heroAvatar-\(bot.name)"
            ) {
                BotAvatarView(spec: bot.spec, size: HermesMetrics.heroAvatarFrame, mood: mood)
                    .opacity(activity.avatarOpacity)
            }
            .frame(width: HermesMetrics.heroDiameter, height: HermesMetrics.heroDiameter)
            Text(bot.displayName)
                .hermesText(.heroName)
                .foregroundStyle(PalTokens.textPrimary.opacity(0.9))
                .lineLimit(1)
        }
        .padding(.vertical, 8)
        .frame(width: 112)
        .overlay(alignment: .topTrailing) {
            if bot.isUnread {
                Circle()
                    .fill(Color(theme.palette.accentBlue))
                    .frame(width: 10, height: 10)
                    .padding(8)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(heroLabel))
    }
}

struct HomeRow: View {
    let bot: BotRow
    let activity: BotActivity
    let mood: AvatarMood

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            BotRowAvatar(bot: bot, activity: activity, mood: mood)
            VStack(alignment: .leading, spacing: HermesMetrics.homeRowTextGap) {
                HStack(alignment: .firstTextBaseline) {
                    Text(bot.displayName)
                        .hermesText(.botName)
                        .foregroundStyle(PalTokens.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if let lastActive = bot.lastActive {
                        Text(RosterTimestamp.label(for: lastActive))
                            .hermesText(.timestamp)
                            .foregroundStyle(PalTokens.textTertiary)
                    }
                    if bot.isUnread {
                        Circle()
                            .fill(Color(theme.palette.accentBlue))
                            .frame(width: 9, height: 9)
                            .accessibilityHidden(true)
                    }
                }
                PreviewLine(bot: bot, activity: activity)
            }
        }
        .padding(.horizontal, HermesMetrics.homeRowInset - 8)
        .frame(height: HermesMetrics.homeRowPitch)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityText))
    }

    private var accessibilityText: String {
        var parts = [bot.displayName]
        if bot.isUnread { parts.append(String(localized: "unread")) }
        if bot.isPrimary { parts.append(String(localized: "primary bot")) }
        if !bot.preview.text.isEmpty { parts.append(bot.preview.text) }
        if let lastActive = bot.lastActive { parts.append(RosterTimestamp.label(for: lastActive)) }
        return parts.joined(separator: ", ")
    }
}

struct BotRowAvatar: View {
    let bot: BotRow
    let activity: BotActivity
    let mood: AvatarMood
    var showsPrimaryBadge = true

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        AvatarBadge(
            diameter: HermesMetrics.homeRowAvatarSlot,
            showsPrimaryBadge: bot.isPrimary && showsPrimaryBadge,
            accessibilityIdentifier: "rowAvatar-\(bot.name)"
        ) {
            BotAvatarView(spec: bot.spec, size: HermesMetrics.homeRowAvatarFrame, mood: mood)
                .opacity(activity.avatarOpacity)
        }
        .frame(width: HermesMetrics.homeRowAvatarSlot, height: HermesMetrics.homeRowAvatarSlot)
        .overlay(alignment: .bottomTrailing) {
            if activity == .working {
                Circle()
                    .fill(Color(theme.palette.workingDot))
                    .frame(width: 13, height: 13)
                    .accessibilityHidden(true)
            }
        }
    }
}

struct PreviewLine: View {
    let bot: BotRow
    let activity: BotActivity

    @Environment(\.hermesTheme) private var theme

    private var glyph: (name: String, color: Color, label: LocalizedStringKey)? {
        if let glyph = activity.glyph { return (glyph.systemName, glyph.color, glyph.label) }
        if case .fromBot = bot.preview.kind { return ("person.bubble", Color(theme.palette.textSecondary), "Message from another bot") }
        return nil
    }

    var body: some View {
        HStack(spacing: 8) {
            if let glyph {
                Image(systemName: glyph.name)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(glyph.color)
                    .accessibilityLabel(Text(glyph.label))
            }
            Text(bot.preview.text.isEmpty ? " " : bot.preview.text)
                .hermesText(.botPreview)
                .foregroundStyle(PalTokens.textSecondary)
                .lineLimit(1)
        }
    }
}
