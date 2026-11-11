#if os(macOS)
import HermesDesign
import HermesRoster
import SwiftUI

struct MacSidebar: View {
    @Bindable var roster: RosterModel
    let connection: ConnectionModel
    let router: AppRouter

    @Environment(MacShell.self) private var shell
    @Environment(RoomsModel.self) private var rooms

    var body: some View {
        Group {
            if shell.isCompact {
                MacRail(roster: roster, connection: connection, router: router)
            } else {
                expanded
            }
        }
        .background(PalTokens.sidebar)
        .overlay(alignment: .trailing) { PalHairline(axis: .vertical) }
    }

    private var expanded: some View {
        ZStack(alignment: .top) {
            let hero = MacShell.hero(in: roster)
            ScrollView {
                VStack(spacing: 3) {
                    if !hero.isEmpty {
                        MacHeroGrid(bots: hero, roster: roster, router: router)
                            .padding(.bottom, 11)
                    }
                    ForEach(MacShell.ordered(roster).dropFirst(hero.count)) { bot in
                        MacBotRow(bot: bot, roster: roster, router: router)
                    }
                    if rooms.isAvailable, !rooms.rooms.isEmpty {
                        MacRoomRows(rooms: rooms, roster: roster, router: router)
                    }
                    if !roster.hiddenBots.isEmpty {
                        MacHiddenBots(roster: roster, router: router)
                            .padding(.top, 6)
                    }
                }
                .padding(.horizontal, 11)
                .padding(.top, MacMetrics.topBarHeight + 7)
                .padding(.bottom, MacMetrics.footerHeight + 8)
            }
            .scrollIndicators(.never)
            .mask(
                VStack(spacing: 0) {
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: MacMetrics.footerHeight - 6)
                }
            )
            .accessibilityIdentifier("rosterScreen")
            .overlay {
                if roster.isLoaded, roster.bots.isEmpty {
                    ContentUnavailableView("No bots yet", systemImage: "face.smiling", description: Text("Bots you create appear here."))
                }
            }
            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                MacSidebarFooter(connection: connection, roster: roster, router: router)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sidebarExpanded")
    }

    private var topBar: some View {
        HStack(spacing: 9) {
            Spacer()
            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 9) {
                    MacIconButton(systemName: "magnifyingglass", label: String(localized: "Search"), identifier: "rosterSearchField") { router.openSearch() }
                    if rooms.canCreate {
                        MacIconButton(systemName: "person.2", label: String(localized: "New Group Chat"), identifier: "createRoomButton") { rooms.showsCreate = true }
                    }
                    MacIconButton(systemName: "plus", label: String(localized: "Create New Bot"), identifier: "createBotButton") { router.present(.createBot) }
                }
            }
        }
        .padding(.trailing, 14)
        .frame(height: MacMetrics.topBarHeight)
    }
}

struct MacIconButton: View {
    let systemName: String
    let label: String
    let identifier: String
    var diameter: CGFloat = 33
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(PalTokens.textSecondary)
                .frame(width: diameter, height: diameter)
                .palElevatedGlass(Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(Text(label))
        .accessibilityIdentifier(identifier)
    }
}

struct MacConnectAppsGlyph: View {
    var size: CGFloat = 16

    var body: some View {
        let cell = size * 0.4
        let gap = size * 0.2
        ZStack(alignment: .topLeading) {
            ForEach(0..<3, id: \.self) { index in
                RoundedRectangle(cornerRadius: size * 0.1, style: .continuous)
                    .strokeBorder(lineWidth: size * 0.1)
                    .frame(width: cell, height: cell)
                    .offset(x: CGFloat(index % 2) * (cell + gap), y: CGFloat(index / 2) * (cell + gap))
            }
            Image(systemName: "plus")
                .font(.system(size: size * 0.5, weight: .semibold))
                .frame(width: cell, height: cell)
                .offset(x: cell + gap, y: cell + gap)
        }
        .frame(width: size, height: size, alignment: .topLeading)
        .accessibilityHidden(true)
    }
}

private struct MacHeroGrid: View {
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

private struct MacBotRow: View {
    let bot: BotRow
    let roster: RosterModel
    let router: AppRouter

    @State private var hovering = false

    private var isSelected: Bool { router.currentBotName == bot.name }

    var body: some View {
        let activity = roster.activity(for: bot.name)
        Button { router.openChat(botName: bot.name) } label: {
            HStack(spacing: 8.5) {
                MacBotAvatar(bot: bot, roster: roster, diameter: 33, showsPrimaryBadge: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(bot.displayName)
                        .hermesText(.botName)
                        .foregroundStyle(PalTokens.textPrimary)
                        .lineLimit(1)
                    PreviewLine(bot: bot, activity: activity)
                }
                Spacer(minLength: 0)
                MacUnreadDot(bot: bot)
            }
            .padding(.leading, 8.5)
            .padding(.trailing, 8)
            .frame(height: 50)
            .background(
                isSelected ? PalTokens.selected : hovering ? PalTokens.hover : Color.clear,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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

struct MacUnreadDot: View {
    let bot: BotRow

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        if bot.isUnread {
            Circle()
                .fill(Color(theme.palette.accentBlue))
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
        }
    }
}

private struct MacHiddenBots: View {
    let roster: RosterModel
    let router: AppRouter

    @AppStorage("mac.sidebar.hiddenExpanded") private var expanded = false
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 3) {
            Button { withAnimation(.snappy(duration: 0.18)) { expanded.toggle() } } label: {
                HStack(spacing: 6) {
                    Text("Hidden Bots")
                        .font(.system(size: 11.5))
                        .foregroundStyle(PalTokens.textTertiary)
                    Spacer(minLength: 0)
                    Text("\(roster.hiddenBots.count)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(PalTokens.textTertiary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(PalTokens.textTertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .opacity(hovering || expanded ? 1 : 0)
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(hovering ? PalTokens.hover : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .accessibilityLabel(Text("Hidden Bots"))
            .accessibilityValue(Text("\(roster.hiddenBots.count)"))
            .accessibilityHint(Text(expanded ? "Collapses the hidden bots" : "Shows the hidden bots"))
            .accessibilityIdentifier("hiddenBotsHeader")
            if expanded {
                VStack(spacing: 3) {
                    ForEach(roster.hiddenBots) { bot in
                        MacBotRow(bot: bot, roster: roster, router: router)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("hiddenBotsList")
                .transition(.opacity)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("hiddenBots")
    }
}

struct MacBotAvatar: View {
    let bot: BotRow
    let roster: RosterModel
    let diameter: CGFloat
    var showsPrimaryBadge = false

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        let activity = roster.activity(for: bot.name)
        AvatarBadge(diameter: diameter, showsPrimaryBadge: showsPrimaryBadge && bot.isPrimary, accessibilityIdentifier: "rowAvatar-\(bot.name)") {
            BotAvatarView(spec: bot.spec, size: diameter * 1.2, mood: roster.avatarMood(for: bot.name))
                .opacity(activity.avatarOpacity)
        }
        .frame(width: diameter, height: diameter)
        .overlay(alignment: showsPrimaryBadge && bot.isPrimary ? .topTrailing : .bottomTrailing) {
            if activity == .working {
                Circle()
                    .fill(Color(theme.palette.workingDot))
                    .frame(width: 9, height: 9)
                    .accessibilityHidden(true)
            }
        }
    }
}

enum MacBotAccessibility {
    static func label(_ bot: BotRow) -> String {
        var parts = [bot.displayName]
        if bot.isUnread { parts.append(String(localized: "unread")) }
        if bot.isPrimary { parts.append(String(localized: "primary bot")) }
        if !bot.preview.text.isEmpty { parts.append(bot.preview.text) }
        if let lastActive = bot.lastActive { parts.append(RosterTimestamp.label(for: lastActive)) }
        return parts.joined(separator: ", ")
    }
}

struct MacAccountAvatar: View {
    let connection: ConnectionModel
    let roster: RosterModel
    var diameter: CGFloat = 33

    @Environment(\.hermesTheme) private var theme

    private var presenceLabel: LocalizedStringKey {
        switch roster.link {
        case .connected: "Connected"
        case .reconnecting: "Reconnecting"
        case .offline: "Offline"
        }
    }

    private var alertColor: Color? {
        switch roster.link {
        case .connected: nil
        case .reconnecting: .orange
        case .offline: Color(theme.palette.textTertiary)
        }
    }

    var body: some View {
        Text(connection.userInitial)
            .font(.system(size: diameter * 0.42, weight: .semibold))
            .foregroundStyle(PalTokens.textPrimary)
            .frame(width: diameter, height: diameter)
            .background(PalTokens.control, in: Circle())
            .overlay(alignment: .bottomTrailing) {
                if let alertColor {
                    Circle()
                        .fill(alertColor)
                        .frame(width: 9, height: 9)
                        .overlay(Circle().stroke(PalTokens.sidebar, lineWidth: 1.5))
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityValue(Text(presenceLabel))
    }
}

private struct MacSidebarFooter: View {
    let connection: ConnectionModel
    let roster: RosterModel
    let router: AppRouter

    @Environment(MacShell.self) private var shell

    var body: some View {
        HStack(spacing: 7) {
            Button { shell.showsAccountMenu.toggle() } label: {
                HStack(spacing: 7) {
                    MacAccountAvatar(connection: connection, roster: roster)
                    Text(connection.userName.isEmpty ? String(localized: "Account") : connection.userName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(PalTokens.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Account and settings"))
            .accessibilityIdentifier("userAvatarButton")
            if router.capabilities.contains(.connectApps) {
                Button { router.presentConnectApps() } label: {
                    MacConnectAppsGlyph(size: 15)
                        .foregroundStyle(PalTokens.textSecondary)
                        .frame(width: 34, height: 34)
                        .palElevatedGlass(Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(String(localized: "Connect apps"))
                .accessibilityLabel(Text("Connect apps"))
                .accessibilityIdentifier("connectAppsButton")
            }
        }
        .padding(.leading, 15)
        .padding(.trailing, 14)
        .frame(height: MacMetrics.footerHeight)
    }
}

private struct MacRail: View {
    @Bindable var roster: RosterModel
    let connection: ConnectionModel
    let router: AppRouter

    @Environment(MacShell.self) private var shell

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 3) {
                    ForEach(Array(MacShell.ordered(roster).enumerated()), id: \.element.id) { index, bot in
                        MacRailItem(bot: bot, roster: roster, router: router)
                            .padding(.bottom, index == 0 ? 21 : 0)
                    }
                }
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
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(PalTokens.textSecondary)
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
            MacBotAvatar(bot: bot, roster: roster, diameter: 34, showsPrimaryBadge: true)
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
