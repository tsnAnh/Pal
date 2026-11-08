import HermesDesign
import HermesRoster
import SwiftUI

struct HomeView: View {
    @Bindable var roster: RosterModel
    let connection: ConnectionModel
    let router: AppRouter

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.hermesTheme) private var theme

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if !roster.pinned.isEmpty {
                    PinnedHero(roster: roster, router: router)
                        .padding(.top, HermesMetrics.heroTopPadding)
                        .padding(.bottom, HermesMetrics.heroRowSpacing)
                }
                ForEach(roster.rows) { bot in
                    NavigationLink(value: AppRoute.chat(botName: bot.name)) {
                        HomeRow(bot: bot, activity: roster.activity(for: bot.name), mood: roster.avatarMood(for: bot.name))
                            .botContextMenu(bot, roster: roster, router: router)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("botRow-\(bot.name)")
                    .accessibilityValue(Text(roster.activity(for: bot.name).accessibilityValue))
                }
            }
            .padding(.bottom, 24)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .accessibilityIdentifier("rosterScreen")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { router.present(.settings) } label: {
                    UserAvatarView(initial: connection.userInitial, link: roster.link)
                }
                .accessibilityLabel(Text("Account and settings"))
                .accessibilityIdentifier("userAvatarButton")
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .topBarTrailing) {
                CircleIconButton(
                    systemName: "plus",
                    accessibilityLabel: String(localized: "Create New Bot"),
                    accessibilityIdentifier: "createBotButton"
                ) { router.present(.createBot) }
            }
            .sharedBackgroundVisibility(.hidden)
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
        .alert(
            Text("Couldn't update the bot"),
            isPresented: Binding(get: { roster.adminError != nil }, set: { if !$0 { roster.dismissAdminError() } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(AdminErrorCopy.message(roster.adminError))
        }
    }
}

enum AdminErrorCopy {
    static func message(_ error: BotAdminError?) -> LocalizedStringKey {
        switch error {
        case .permissionDenied: "This device isn't allowed to change bots."
        case .botNotFound: "That bot no longer exists."
        case .conflict: "Another device changed this bot at the same time. Try again."
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
            .frame(width: HermesMetrics.circleButtonDiameter, height: HermesMetrics.circleButtonDiameter)
            .background(Color(theme.palette.circleButtonFill), in: Circle())
            .overlay(Circle().strokeBorder(Color(theme.palette.circleButtonStroke), lineWidth: HermesMetrics.circleButtonStrokeWidth))
            .overlay(alignment: .bottomTrailing) {
                Circle()
                    .fill(presenceColor)
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(Color(theme.palette.canvas), lineWidth: 2))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityValue(Text(presenceLabel))
    }
}

private struct PinnedHero: View {
    let roster: RosterModel
    let router: AppRouter

    private static let cellWidth: CGFloat = 112

    var body: some View {
        ViewThatFits(in: .horizontal) {
            cells.frame(maxWidth: .infinity)
            ScrollView(.horizontal, showsIndicators: false) {
                cells.padding(.horizontal, HermesMetrics.homeRowInset)
            }
        }
    }

    private var cells: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(roster.pinned) { bot in
                NavigationLink(value: AppRoute.chat(botName: bot.name)) {
                    HeroCell(bot: bot, activity: roster.activity(for: bot.name), mood: roster.avatarMood(for: bot.name))
                        .frame(width: Self.cellWidth)
                        .botContextMenu(bot, roster: roster, router: router)
                }
                .buttonStyle(.plain)
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
                .foregroundStyle(Color(theme.palette.textPrimary))
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(bot.isPrimary ? "\(bot.displayName), primary bot" : "\(bot.displayName), pinned"))
    }
}

struct HomeRow: View {
    let bot: BotRow
    let activity: BotActivity
    let mood: AvatarMood

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        HStack(spacing: 15) {
            BotRowAvatar(bot: bot, activity: activity, mood: mood)
            VStack(alignment: .leading, spacing: HermesMetrics.homeRowTextGap) {
                HStack(alignment: .firstTextBaseline) {
                    Text(bot.displayName)
                        .hermesText(.botName)
                        .foregroundStyle(Color(theme.palette.textPrimary))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if let lastActive = bot.lastActive {
                        Text(RosterTimestamp.label(for: lastActive))
                            .hermesText(.timestamp)
                            .foregroundStyle(Color(theme.palette.textTertiary))
                    }
                }
                PreviewLine(bot: bot, activity: activity)
            }
        }
        .padding(.horizontal, HermesMetrics.homeRowInset)
        .frame(height: HermesMetrics.homeRowPitch)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityText))
    }

    private var accessibilityText: String {
        var parts = [bot.displayName]
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
                .foregroundStyle(Color(theme.palette.textSecondary))
                .lineLimit(1)
        }
    }
}
