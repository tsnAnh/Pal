#if os(macOS)
import AppKit
import PalDesign
import PalDiagnostics
import SwiftUI

@MainActor
@Observable
final class MacShell {
    static let compactKey = "mac.sidebar.compact"
    private static let layoutAnimation = Animation.snappy(duration: 0.22)

    private(set) var isCompact: Bool
    private var inspectorVisible = false
    var showsInspector: Bool {
        get { inspectorVisible }
        set { withAnimation(Self.layoutAnimation) { inspectorVisible = newValue } }
    }
    var showsShortcuts = false
    var showsAccountMenu = false
    var messageMenu: MacMessageMenuRequest?
    var attachMenu: MacAttachMenuRequest?
    var settingsSection = MacSettingsSection.general
    private(set) var composerFocusToken = 0
    private(set) var findToken = 0

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isCompact = defaults.bool(forKey: Self.compactKey)
    }

    func toggleCompact() {
        withAnimation(Self.layoutAnimation) { isCompact.toggle() }
        defaults.set(isCompact, forKey: Self.compactKey)
    }

    func toggleInspector() {
        showsInspector.toggle()
    }

    func focusComposer() {
        composerFocusToken += 1
    }

    func beginFind() {
        findToken += 1
    }

    static func ordered(_ roster: RosterModel) -> [BotRow] {
        let lead = hero(in: roster)
        let leadNames = Set(lead.map(\.name))
        var rest = roster.visibleBots.filter { !leadNames.contains($0.name) }
        if lead.isEmpty, let index = rest.firstIndex(where: \.isPrimary), index > 0 {
            rest.insert(rest.remove(at: index), at: 0)
        }
        return lead + rest
    }

    static func hero(in roster: RosterModel) -> [BotRow] {
        roster.pinned
    }
}

struct MacSidebarResizeHandle: View {
    let width: DragWidth
    @State private var hovering = false

    var body: some View {
        Color.clear
            .frame(width: 8)
            .offset(x: 4)
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag in width.drag(by: Double(drag.translation.width)) }
                    .onEnded { _ in width.endDrag() }
            )
            .onDisappear {
                if hovering { NSCursor.pop() }
                width.endDrag()
            }
            .accessibilityHidden(true)
    }
}

private struct MacSidebarFrame: ViewModifier {
    let width: DragWidth
    let compact: Bool

    func body(content: Content) -> some View {
        content.frame(width: compact ? MacMetrics.railWidth : CGFloat(width.live))
    }
}

extension DragWidth {
    static func sidebar(defaults: UserDefaults = .standard) -> DragWidth {
        let stored = defaults.object(forKey: MacMetrics.sidebarWidthKey) as? Double ?? Double(MacMetrics.sidebarWidth)
        let range = Double(MacMetrics.sidebarWidthRange.lowerBound)...Double(MacMetrics.sidebarWidthRange.upperBound)
        return DragWidth(stored: stored, range: range) { defaults.set($0, forKey: MacMetrics.sidebarWidthKey) }
    }
}

enum MacMetrics {
    static let sidebarWidth: CGFloat = 280
    static let sidebarWidthRange: ClosedRange<CGFloat> = 240...400
    static let sidebarWidthKey = "mac.sidebar.width"
    static let railWidth: CGFloat = 80
    static let inspectorWidth: CGFloat = 320
    static let chatColumn: CGFloat = 882
    static let topBarHeight: CGFloat = 55
    static let topBarCenter: CGFloat = 27.5
    static let footerHeight: CGFloat = 64
    static let trafficLightCenter = CGPoint(x: 21, y: 20)
    static let trafficLightPitch: CGFloat = 21
}

struct MacShellView<Destination: View>: View {
    @Bindable var roster: RosterModel
    let connection: ConnectionModel
    @Bindable var router: AppRouter
    let bots: BotsKit
    @ViewBuilder let destination: (AppRoute) -> Destination

    @Environment(MacShell.self) private var shell
    @State private var sidebarWidth = DragWidth.sidebar()

    var body: some View {
        PalPerf.interval("shell.body") { shellContent }
    }

    private var shellContent: some View {
        HStack(spacing: 0) {
            MacSidebar(roster: roster, connection: connection, router: router)
                .modifier(MacSidebarFrame(width: sidebarWidth, compact: shell.isCompact))
                .overlay(alignment: .trailing) {
                    if !shell.isCompact { MacSidebarResizeHandle(width: sidebarWidth) }
                }
            detail
            if shell.showsInspector, router.path.count == 1, let name = router.currentBotName, roster.bot(named: name) != nil {
                MacInspector(botName: name, roster: roster, router: router, bots: bots)
                    .id(name)
                    .frame(width: MacMetrics.inspectorWidth)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(PalTokens.content)
        .background(MacWindowChrome())
        .overlay { MacMessageMenuHost() }
        .onChange(of: router.path, initial: true) { _, path in
            guard case .botProfile(let name)? = path.last else { return }
            router.path = [.chat(botName: name)]
            shell.showsInspector = true
        }
        .onChange(of: roster.bots, initial: true) { _, _ in openLaunchConversationIfNeeded() }
        .onChange(of: router.path.isEmpty) { _, _ in openLaunchConversationIfNeeded() }
        .onChange(of: router.currentBotName) { _, name in
            guard let name, roster.bot(named: name) != nil else { return }
            roster.rememberOpened(bot: name)
        }
    }

    private func openLaunchConversationIfNeeded() {
        guard router.path.isEmpty, let bot = roster.launchBot else { return }
        router.openChat(botName: bot.name)
    }

    private var detail: some View {
        NavigationStack(path: detailPath) {
            Group {
                if let first = router.path.first {
                    destination(first).id(first)
                } else {
                    ContentUnavailableView {
                        Label("Pick a bot", palIcon: "bubble.left.and.bubble.right")
                    } description: {
                        Text("Choose a bot from the list to start chatting.")
                    }
                }
            }
            .navigationDestination(for: AppRoute.self) { route in
                destination(route).navigationBarBackButtonHidden(true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private var detailPath: Binding<[AppRoute]> {
        Binding(
            get: { Array(router.path.dropFirst()) },
            set: { router.path = Array(router.path.prefix(1)) + $0 }
        )
    }
}
#endif
