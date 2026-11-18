#if os(macOS)
import PalDesign
import PalRoster
import SwiftUI

struct MacHeroGrid: View {
    let bots: [BotRow]
    let roster: RosterModel
    let router: AppRouter

    private static let perRow = 2

    var body: some View {
        VStack(spacing: 8) {
            ForEach(Array(stride(from: 0, to: bots.count, by: Self.perRow)), id: \.self) { start in
                HStack(spacing: 8) {
                    ForEach(bots[start..<min(start + Self.perRow, bots.count)]) { bot in
                        MacPrimaryTile(bot: bot, roster: roster, router: router)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pinnedHero")
    }
}

private struct MacPrimaryTile: View {
    let bot: BotRow
    let roster: RosterModel
    let router: AppRouter

    @State private var hovering = false

    private var isSelected: Bool { router.currentBotName == bot.name }

    var body: some View {
        let activity = roster.activity(for: bot.name)
        Button { router.openChat(botName: bot.name) } label: {
            VStack(spacing: 4) {
                AvatarBadge(diameter: 53, showsPrimaryBadge: bot.isPrimary, accessibilityIdentifier: "heroAvatar-\(bot.name)") {
                    BotAvatarView(spec: bot.spec, size: 53 * 1.25, mood: roster.avatarMood(for: bot.name))
                        .opacity(activity.avatarOpacity)
                }
                .frame(width: 53, height: 53)
                Text(bot.displayName)
                    .hermesText(.heroName)
                    .foregroundStyle(PalTokens.textPrimary.opacity(0.9))
                    .lineLimit(1)
            }
            .padding(.horizontal, 6)
            .frame(width: 87, height: 84)
            .overlay(alignment: .topTrailing) { MacUnreadDot(bot: bot).padding(8) }
            .background(
                isSelected ? PalTokens.selected : hovering ? PalTokens.hover : Color.clear,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(MacBotAccessibility.label(bot)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .botContextMenu(bot, roster: roster, router: router)
        .accessibilityIdentifier("botRow-\(bot.name)")
        .accessibilityValue(Text(activity.accessibilityValue))
    }
}
#endif
