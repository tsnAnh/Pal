#if os(macOS)
import PalDesign
import PalRoster
import SwiftUI

struct MacRail: View {
    @Bindable var roster: RosterModel
    let connection: ConnectionModel
    let router: AppRouter

    @Environment(MacShell.self) private var shell

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(Array(MacShell.ordered(roster).enumerated()), id: \.element.id) { index, bot in
                        MacRailItem(bot: bot, roster: roster, router: router)
                            .padding(.bottom, index == 0 ? 21 : 0)
                    }
                }
                .boundedToColumn()
                .frame(maxWidth: .infinity)
                .padding(.top, 44)
                .padding(.bottom, 8)
            }
            .scrollIndicators(.never)
            .accessibilityIdentifier("rosterScreen")
            VStack(spacing: 0) {
                VStack(spacing: 3) {
                    MacRailAction(systemName: "plus", label: String(localized: "Create New Bot"), identifier: "createBotButton") { router.present(.createBot) }
                    if router.capabilities.contains(.connectApps) {
                        Button { router.presentConnectApps() } label: {
                            MacConnectAppsGlyph(size: 15)
                                .foregroundStyle(PalTokens.textSecondary)
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(String(localized: "Connect apps"))
                        .accessibilityLabel(Text("Connect apps"))
                        .accessibilityIdentifier("connectAppsButton")
                    }
                    if router.capabilities.contains(.kanban) {
                        Button { router.presentKanban() } label: {
                            PalIcon("rectangle.split.3x1", ink: .secondary)
                                .font(.system(size: 15))
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(String(localized: "Pal Kanban"))
                        .accessibilityLabel(Text("Pal Kanban"))
                        .accessibilityIdentifier("kanbanButton")
                    }
                }
                Button { shell.showsAccountMenu.toggle() } label: {
                    MacAccountAvatar(connection: connection, roster: roster, diameter: 33)
                }
                .padding(.top, 10)
                .buttonStyle(.plain)
                .help(connection.userName.isEmpty ? String(localized: "Account and settings") : connection.userName)
                .accessibilityLabel(Text("Account and settings"))
                .accessibilityIdentifier("userAvatarButton")
            }
            .padding(.bottom, 17)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sidebarRail")
    }
}

private struct MacRailAction: View {
    let systemName: String
    let label: String
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            PalIcon(systemName, ink: .secondary)
                .font(.system(size: 15, weight: .regular))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(Text(label))
        .accessibilityIdentifier(identifier)
    }
}

private struct MacRailItem: View {
    let bot: BotRow
    let roster: RosterModel
    let router: AppRouter

    @State private var hovering = false

    private var isSelected: Bool { router.currentBotName == bot.name }

    var body: some View {
        let activity = roster.activity(for: bot.name)
        Button { router.openChat(botName: bot.name) } label: {
            MacBotAvatar(bot: bot, roster: roster, diameter: MacMetrics.rowAvatar, showsPrimaryBadge: true)
                .frame(width: 50, height: 50)
                .overlay(alignment: .topTrailing) { MacUnreadDot(bot: bot).padding(7) }
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
        .help(bot.displayName)
        .botContextMenu(bot, roster: roster, router: router)
        .accessibilityIdentifier("botRow-\(bot.name)")
        .accessibilityValue(Text(activity.accessibilityValue))
    }
}
#endif
