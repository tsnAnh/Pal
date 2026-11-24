#if os(macOS)
import PalBotProfile
import PalDesign
import SwiftUI

struct MacModalHost: View {
    let connection: ConnectionModel
    let roster: RosterModel
    @Bindable var router: AppRouter
    let hostPool: DeviceHostPool
    @Bindable var createBot: CreateBotModel
    let hub: SettingsHub

    @Environment(MacShell.self) private var shell
    @Environment(\.macWindowSize) private var windowSize
    @Environment(\.macDialogCenter) private var dialogs
    @Environment(\.macSheetCenter) private var sheets
    @State private var confirmingSignOut = false
    @State private var confirmingAdd = false

    init(connection: ConnectionModel, roster: RosterModel, router: AppRouter, hostPool: DeviceHostPool, createBot: CreateBotModel, hub: SettingsHub) {
        self.connection = connection
        self.roster = roster
        self.router = router
        self.hostPool = hostPool
        self.createBot = createBot
        self.hub = hub
    }

    var body: some View {
        ZStack {
            if shell.showsShortcuts {
                MacModalScrim { shell.showsShortcuts = false }
                MacModalPanel(
                    size: .wide, identifier: "shortcutsSheet", closeIdentifier: "shortcutsClose", close: { shell.showsShortcuts = false },
                    content: { MacShortcutsSheet() }
                )
            } else if router.sheet == .kanban {
                KanbanSurface(connection: connection, roster: roster, close: { router.dismissSheet() })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.top, MacMetrics.trafficLightCenter.y + MacMetrics.trafficLightPitch / 2)
                    .background(PalTokens.content)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("kanbanPanel")
                    .transition(.opacity)
            } else if let sheet = router.sheet {
                MacModalScrim { router.dismissSheet() }
                panel(for: sheet)
            } else if let bot = router.renamingBot.flatMap({ roster.bot(named: $0) }) {
                MacModalScrim { router.renamingBot = nil }
                MacModalPanel(
                    size: .compact, identifier: "renameBotSheet", closeIdentifier: "renameBotClose", close: { router.renamingBot = nil },
                    content: { MacRenameBot(bot: bot, roster: roster, router: router) }
                )
                .id(bot.name)
            } else if router.isSearching {
                MacModalScrim { router.closeSearch() }
                MacModalPanel(
                    size: .palette, identifier: "searchPanel", closeIdentifier: "searchPanelClose", close: { router.closeSearch() },
                    content: { MacPalette(roster: roster, router: router) }
                )
                .transition(.scale(scale: 0.98).combined(with: .opacity))
            }
            if shell.showsAccountMenu, router.sheet == nil, !router.isSearching, !shell.showsShortcuts {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { shell.showsAccountMenu = false }
                    .accessibilityHidden(true)
                MacAccountMenu(hub: hub, router: router, addAccount: { confirmingAdd = true }, signOut: { confirmingSignOut = true })
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(.leading, 15)
                    .padding(.bottom, MacMetrics.footerHeight - 12)
                    .transition(.scale(scale: 0.96, anchor: .bottomLeading).combined(with: .opacity))
            }
            LocalEngineSetupHost(engine: connection.localEngine)
            if let sheets {
                MacSheetLayer(center: sheets)
            }
            if let dialogs {
                MacDialogLayer(center: dialogs, window: windowSize?.size ?? .zero)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGSize.self, of: \.size) { windowSize?.update($0) }
        .ignoresSafeArea(.container, edges: .top)
        .animation(.snappy(duration: 0.2), value: shell.showsShortcuts)
        .animation(.snappy(duration: 0.2), value: router.sheet)
        .animation(.snappy(duration: 0.2), value: router.isSearching)
        .animation(.snappy(duration: 0.2), value: router.renamingBot)
        .botManagementDialogs(roster: roster, router: router)
        .animation(.snappy(duration: 0.18), value: shell.showsAccountMenu)
        .task { await hub.refresh() }
        .onChange(of: router.sheet) { _, sheet in
            if sheet == .settings { Task { await hub.refresh() } }
        }
        .onChange(of: shell.showsAccountMenu) { _, shows in
            if shows { Task { await hub.refresh() } }
        }
        .macConfirm(isPresented: $confirmingSignOut) {
            MacDialogContent(
                String(localized: "Sign out of Pal on this device?"),
                actions: [
                    MacDialogAction(String(localized: "Sign Out"), role: .destructive) { Task { await connection.signOut() } },
                    MacDialogAction(String(localized: "Cancel"), role: .cancel)
                ]
            )
        }
        .macConfirm(isPresented: $confirmingAdd) {
            MacDialogContent(
                String(localized: "Signing in with another account replaces this one on this device."),
                actions: [
                    MacDialogAction(String(localized: "Continue"), role: .destructive) { Task { await connection.signOut() } },
                    MacDialogAction(String(localized: "Cancel"), role: .cancel)
                ]
            )
        }
    }

    private var createBotEscape: EscapePolicy {
        createBot.isCreating ? .blocked(.inFlight) : EscapePolicy(blocking: .unsavedInput, when: !createBot.name.isEmpty)
    }

    @ViewBuilder
    private func panel(for sheet: AppSheet) -> some View {
        switch sheet {
        case .settings:
            MacModalPanel(
                size: .full, identifier: "settingsSheetPanel", closeIdentifier: "settingsClose", close: { router.dismissSheet() },
                content: { MacSettingsModal(hub: hub, connection: connection, section: Bindable(shell).settingsSection) }
            )
        case .createBot:
            MacModalPanel(
                size: .form,
                closePlacement: .trailing,
                identifier: "createBotSheet",
                closeIdentifier: "createBotClose",
                close: { router.dismissSheet() },
                content: { MacCreateBot(model: createBot, roster: roster, router: router).palEscapePolicy(createBotEscape) }
            )
        case .connectApps:
            MacModalPanel(
                size: .full, clearClose: true, identifier: "connectAppsPanel", closeIdentifier: "connectApps-close",
                close: { router.dismissSheet() },
                content: {
                    MacConnectAppsPanel(connection: connection, hostPool: hostPool, roster: roster, profile: router.connectAppsProfile) {
                        router.dismissSheet()
                    }
                    .id(router.connectAppsProfile ?? "")
                }
            )
        case .approvals:
            MacModalPanel(
                size: .full, identifier: "approvalsPanel", closeIdentifier: "approvals-close",
                close: { router.dismissSheet() },
                content: { ApprovalsView(bots: roster.heldDraftBots(for: router.approvalsProfile)) { router.dismissSheet() } }
            )
        case .kanban:
            EmptyView()
        }
    }
}

struct MacAccountMenu: View {
    let hub: SettingsHub
    let router: AppRouter
    let addAccount: () -> Void
    let signOut: () -> Void

    @Environment(MacShell.self) private var shell

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 12, style: .continuous) }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            item("chart.bar", String(localized: "Usage"), value: hub.usageHeadline, showsChevron: true, identifier: "accountMenuUsage") {
                open(.usage)
            }
            item("gearshape", String(localized: "Settings"), identifier: "accountMenuSettings") {
                open(.general)
            }
            PalHairline(color: PalTokens.divider)
                .padding(.horizontal, 10)
                .frame(height: 10)
            item("person.badge.plus", String(localized: "Add account"), identifier: "accountMenuAdd") {
                shell.showsAccountMenu = false
                addAccount()
            }
            item("rectangle.portrait.and.arrow.right", String(localized: "Log out"), identifier: "accountMenuLogout") {
                shell.showsAccountMenu = false
                signOut()
            }
        }
        .padding(4)
        .frame(width: 208)
        .background(PalTokens.elevated.opacity(0.82), in: shape)
        .palGlass(shape, interactive: false)
        .overlay(shape.strokeBorder(PalTokens.panelBorder, lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 23, y: 10)
        .palEscape(.menu) { shell.showsAccountMenu = false }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("accountMenu")
    }

    private func open(_ section: MacSettingsSection) {
        shell.showsAccountMenu = false
        shell.settingsSection = section
        router.present(.settings)
    }

    private func item(_ symbol: String, _ title: String, value: String? = nil, showsChevron: Bool = false, identifier: String, action: @escaping () -> Void) -> some View {
        MacMenuItem(symbol: symbol, title: title, value: value, showsChevron: showsChevron, identifier: identifier, action: action)
    }
}

private struct MacMenuItem: View {
    let symbol: String
    let title: String
    let value: String?
    let showsChevron: Bool
    let identifier: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                PalIcon(symbol, ink: .secondary)
                    .font(.system(size: 12))
                    .frame(width: 12)
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(PalTokens.textPrimary)
                Spacer(minLength: 8)
                if let value {
                    Text(value)
                        .font(.system(size: 12))
                        .foregroundStyle(PalTokens.textTertiary)
                        .lineLimit(1)
                }
                if showsChevron {
                    PalIcon("chevron.right", ink: .tertiary)
                        .font(.system(size: 9, weight: .medium))
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(hovering ? PalTokens.hover : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(Text([title, value].compactMap { $0 }.joined(separator: ", ")))
        .accessibilityIdentifier(identifier)
    }
}
#endif
