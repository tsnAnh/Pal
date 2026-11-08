import HermesDesign
import HermesRoster
import SwiftUI

struct RosterView: View {
    @Bindable var roster: RosterModel
    let connection: ConnectionModel
    let openSettings: () -> Void

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if let hero = roster.hero {
                    NavigationLink(value: hero.name) {
                        HeroView(bot: hero, activity: roster.activity(for: hero.name), mood: roster.avatarMood(for: hero.name))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("botRow-\(hero.name)")
                    .accessibilityValue(Text(roster.activity(for: hero.name).accessibilityValue))
                }
                ForEach(roster.rows) { bot in
                    NavigationLink(value: bot.name) {
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
        }
        .toolbarTitleDisplayMode(.inline)
        .background(Color.canvas)
        .safeAreaBar(edge: .bottom) {
            SearchField(text: $roster.query)
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

    private var presenceColor: Color {
        switch link {
        case .connected: .blue
        case .reconnecting: .orange
        case .offline: .gray
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
            .foregroundStyle(Color.onCard)
            .frame(width: 32, height: 32)
            .overlay(alignment: .bottomTrailing) {
                Circle()
                    .fill(presenceColor)
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(Color.badgeRing, lineWidth: 2))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityValue(Text(presenceLabel))
    }
}

private struct HeroView: View {
    let bot: BotRow
    let activity: BotActivity
    let mood: AvatarMood

    var body: some View {
        VStack(spacing: 12) {
            BotAvatarView(spec: bot.spec, size: 136, mood: mood)
                .opacity(activity.avatarOpacity)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Color.orange, in: Circle())
                        .overlay(Circle().stroke(Color.badgeRing, lineWidth: 3))
                        .offset(x: 4, y: 4)
                }
            Text(bot.displayName)
                .font(.title3)
                .foregroundStyle(.secondary)
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

    var body: some View {
        HStack(spacing: 14) {
            BotAvatarView(spec: bot.spec, size: 56, mood: mood)
                .opacity(activity.avatarOpacity)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(bot.displayName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if let lastActive = bot.lastActive {
                        Text(RosterTimestamp.label(for: lastActive))
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
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
                        .foregroundStyle(.secondary)
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

private struct SearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("", text: $text, prompt: Text("Search"))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .accessibilityLabel(Text("Search bots"))
                .accessibilityIdentifier("rosterSearchField")
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear search"))
            }
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 52)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}
