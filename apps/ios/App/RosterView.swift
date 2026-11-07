import HermesDesign
import HermesRoster
import SwiftUI

struct RosterView: View {
    @Bindable var roster: RosterModel
    let connection: ConnectionModel
    let openSettings: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.hermesTheme) private var theme

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if let hero = roster.hero {
                    NavigationLink(value: AppRoute.chat(botName: hero.name)) {
                        HeroView(bot: hero, activity: roster.activity(for: hero.name), mood: roster.avatarMood(for: hero.name))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("botRow-\(hero.name)")
                    .accessibilityValue(Text(roster.activity(for: hero.name).accessibilityValue))
                }
                ForEach(roster.rows) { bot in
                    NavigationLink(value: AppRoute.chat(botName: bot.name)) {
                        RosterRowView(bot: bot, activity: roster.activity(for: bot.name), mood: roster.avatarMood(for: bot.name))
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
                Button(action: openSettings) {
                    UserAvatarView(initial: connection.userInitial, link: roster.link)
                }
                .accessibilityLabel(Text("Account and settings"))
                .accessibilityIdentifier("userAvatarButton")
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .toolbarTitleDisplayMode(.inline)
        .background(Color(theme.palette.canvas))
        .safeAreaBar(edge: .bottom) {
            FloatingSearchBar(
                text: $roster.query,
                accessibilityLabel: "Search bots",
                accessibilityIdentifier: "rosterSearchField"
            )
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { roster.nudge() }
        }
        .overlay {
            if roster.isLoaded, roster.bots.isEmpty {
                ContentUnavailableView("No bots yet", systemImage: "face.smiling", description: Text("Bots you create appear here."))
            }
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
            .frame(width: 44, height: 44)
            .background(Color(theme.palette.circleButtonFill), in: Circle())
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

private struct HeroView: View {
    let bot: BotRow
    let activity: BotActivity
    let mood: AvatarMood

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        VStack(spacing: 12) {
            AvatarBadge(diameter: 136, showsPrimaryBadge: true, accessibilityIdentifier: "heroAvatar") {
                BotAvatarView(spec: bot.spec, size: 136, mood: mood)
                    .opacity(activity.avatarOpacity)
            }
            Text(bot.displayName)
                .font(.title3)
                .foregroundStyle(Color(theme.palette.textSecondary))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(bot.displayName), primary bot"))
    }
}

private struct RosterRowView: View {
    let bot: BotRow
    let activity: BotActivity
    let mood: AvatarMood

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        HStack(spacing: 14) {
            BotAvatarView(spec: bot.spec, size: 56, mood: mood)
                .opacity(activity.avatarOpacity)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(bot.displayName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color(theme.palette.textPrimary))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if let lastActive = bot.lastActive {
                        Text(RosterTimestamp.label(for: lastActive))
                            .font(.subheadline)
                            .foregroundStyle(Color(theme.palette.textTertiary))
                    }
                }
                HStack(spacing: 6) {
                    if let glyph = activity.glyph {
                        Image(systemName: glyph.systemName)
                            .foregroundStyle(glyph.color)
                            .accessibilityLabel(Text(glyph.label))
                    }
                    Text(bot.preview.isEmpty ? " " : bot.preview)
                        .font(.body)
                        .foregroundStyle(Color(theme.palette.textSecondary))
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
