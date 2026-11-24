import PalBotProfile
import PalChat
import PalDesign
import PalDiagnostics
import PalProtocol
import SwiftUI

struct ChatTranscriptList: View {
    let model: ChatModel
    @Bindable var scroll: ChatScrollController
    let teach: TeachModel
    let router: AppRouter

    @State private var connectionIsSlow = false
    @LazyState private var desk: ChatDeskFeed
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: ChatModel, scroll: ChatScrollController, teach: TeachModel, router: AppRouter) {
        self.model = model
        self.scroll = scroll
        self.teach = teach
        self.router = router
        _desk = LazyState { ChatDeskFeed(botName: model.bot.name, connection: model.roster.connection) }
    }

    var body: some View {
        let _ = PalPerf.event("chat.scroll.body") // swiftlint:disable:this redundant_discardable_let
        let _ = ChatOpenMetrics.listBody() // swiftlint:disable:this redundant_discardable_let
        ScrollView {
            ChatTranscriptRows(model: model, scroll: scroll, router: router, desk: desk.desk, connectionIsSlow: connectionIsSlow)
        }
        .scrollPosition($scroll.position)
        .defaultScrollAnchor(.bottom)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .safeAreaPadding(.bottom, ChatMetrics.composerClearance)
        .task(id: model.bot.name) { await desk.run() }
        .overlay { ChatOpeningOverlay(model: model, hidesIntro: !desk.desk.cards.isEmpty) }
        .scrollDismissesKeyboard(.interactively)
        .palHiddenScrollEdge(for: .all)
        .safeAreaInset(edge: .top, spacing: 0) { TeachBanner(model: teach, surface: .chat) }
        .safeAreaInset(edge: .top, spacing: 0) { ChatAutoApproveBanner(model: model) }
        .teachPresentations(teach, surface: .chat)
        .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }, action: { _, new in scroll.observe(new) })
        .onScrollPhaseChange { _, phase in scroll.observe(phase) }
        .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.01) { scroll.visibleRowsChanged($0) }
        .modifier(ChatRowsSync(model: model, scroll: scroll))
        .modifier(ChatOlderPaging(model: model, scroll: scroll))
        .modifier(ChatScreenAccessibility(model: model))
        .paneOverflowProbe("chat.pane")
        .overlay(alignment: .bottom) {
            if scroll.showsJumpButton, !model.isFinding {
                ChatJumpToNewest(scroll: scroll)
                    .padding(.bottom, 4)
                    .transition(pop.transition)
            }
        }
        .animation(pop.animation, value: scroll.showsJumpButton)
        .modifier(ChatFindReveal(model: model, scroll: scroll))
        .task(id: model.connection) {
            connectionIsSlow = false
            guard model.connection != .live else { return }
            guard await LoadingPolicy.waited(model.connection == .reconnecting ? Self.reconnectingNoticeDelay : Self.catchUpNoticeDelay) else { return }
            connectionIsSlow = model.connection != .live
        }
    }

    private static let reconnectingNoticeDelay = Duration.seconds(1)
    private static let catchUpNoticeDelay = LoadingPolicy.catchUpNoticeWindow

    private var pop: PalMotion.Pop { PalMotion.Pop(reduceMotion: reduceMotion) }
}

private struct ChatTranscriptRows: View {
    let model: ChatModel
    let scroll: ChatScrollController
    let router: AppRouter
    let desk: ChatDeskModel
    let connectionIsSlow: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if os(macOS)
    @Environment(MacShell.self) private var shell
    #endif

    private func openModelProviders() {
        #if os(macOS)
        shell.settingsSection = .providers
        router.present(.settings)
        #else
        router.presentSettings(route: .modelProviders)
        #endif
    }

    var body: some View {
        let _ = PalPerf.event("chat.list.body") // swiftlint:disable:this redundant_discardable_let
        let source = model.rowContextSource
        let ink = BubblePalette.ink(accent: source.accent)
        LazyVStack(alignment: .leading, spacing: 0) {
            if !model.rows.isEmpty {
                OlderHistoryRow(state: model.olderHistoryShown, ink: ink) { model.wantOlder() }
                    .chatListRow()
                    .padding(.top, 8)
            }
            ForEach(model.windowRows) { row in
                ChatRowView(row: row, context: source.context(for: row), model: model, openModelProviders: openModelProviders) { link in
                    router.push(.botThread(BotThreadRoute(
                        botName: model.bot.name,
                        threadID: link.threadID,
                        focusExchangeID: link.exchangeID
                    )))
                }
                .equatable()
                .chatListRow()
                .modifier(ChatRowHeightFloor(floor: scroll.minHeight(for: row)) { scroll.rowLaidOut(row.id, frame: $0) })
            }
            VStack(spacing: 0) { footer(ink: ink) }
                .animation(PalMotion.Pop(reduceMotion: reduceMotion).animation, value: showsWorkingRow)
                .chatListRow()
            ForEach(desk.cards) { card in
                ChatDeskCardView(card: card, botName: model.bot.displayName) { choice in
                    Task { await desk.decide(card.id, choice) }
                }
                .padding(.top, ChatMetrics.senderSwitchGap)
                .frame(maxWidth: ChatDeskCardView.maxWidth)
                .frame(maxWidth: .infinity)
                .chatListRow()
            }
        }
        .scrollTargetLayout()
        .coordinateSpace(.named(ChatScrollController.contentSpace))
        .paneOverflowProbe("chat.list")
        #if os(iOS)
        .containerRelativeFrame(.horizontal)
        #endif
    }

    @ViewBuilder
    private func footer(ink: Color) -> some View {
        if connectionIsSlow {
            connectionStatus
                .padding(.top, 12)
        }
        if showsWorkingRow {
            ChatWorkingRow(status: model.workingStatus, ink: ink, avatar: model.bot.spec)
                .padding(.top, ChatMetrics.senderSwitchGap)
                .transition(PalMotion.Pop(reduceMotion: reduceMotion).transition)
        }
    }

    private var showsWorkingRow: Bool { model.isRunning && !model.hasPendingPrompt }

    @ViewBuilder
    private var connectionStatus: some View {
        switch model.connection {
        case .reconnecting:
            ChatStatusLine(text: String(localized: "Reconnecting…"), symbol: "clock")
                .accessibilityIdentifier("reconnectingIndicator")
        case .connecting, .live:
            if model.isCatchingUp {
                ChatStatusLine(text: String(localized: "Checking for new messages…"), symbol: "clock")
                    .accessibilityIdentifier("chatStatusLine")
            }
        }
    }
}

private struct ChatRowHeightFloor: ViewModifier {
    let floor: CGFloat?
    let laidOut: (CGRect) -> Void
    @State private var settled = false

    private static let settleLimit = Duration.seconds(1)

    func body(content: Content) -> some View {
        let _ = ChatOpenMetrics.rowBody() // swiftlint:disable:this redundant_discardable_let
        content
            .onGeometryChange(for: CGRect.self) { // perf-lint: ok
                $0.frame(in: .named(ChatScrollController.contentSpace))
            } action: { frame in
                laidOut(frame)
                if let floor, !settled, frame.height >= floor - 0.5 { settled = true }
            }
            .frame(minHeight: settled ? nil : floor, alignment: .top)
            .task {
                guard floor != nil, !settled else { return }
                try? await Task.sleep(for: Self.settleLimit)
                settled = true
            }
    }
}

private struct ChatOpeningOverlay: View {
    let model: ChatModel
    let hidesIntro: Bool

    var body: some View {
        if model.isOpening {
            DelayedReveal(after: ChatLoading.delay) {
                Text("Loading…")
                    .hermesText(.chatStatus)
                    .foregroundStyle(PalTokens.textSecondary)
                    .accessibilityIdentifier("chatLoading")
            }
        } else if model.rows.isEmpty, !model.isRunning, !hidesIntro {
            NewChatIntro(bot: model.bot, mood: model.avatarMood, suggestion: Self.firstSuggestion) {
                model.send(Self.firstSuggestion)
            }
            .padding(.horizontal, ChatMetrics.edgeMargin)
        }
    }

    private static let firstSuggestion = String(localized: "Tell me about yourself")
}

private struct ChatJumpToNewest: View {
    let scroll: ChatScrollController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollToBottomButton(newCount: scroll.unseen) { scroll.jumpToBottom(animated: !reduceMotion) }
    }
}

private struct ChatAutoApproveBanner: View {
    let model: ChatModel

    var body: some View {
        AutoApproveBanner(sessionID: model.bot.conversationID)
    }
}
