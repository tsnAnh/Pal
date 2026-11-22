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

    @State private var chrome = EdgeInsets()
    @State private var connectionIsSlow = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let _ = PalPerf.event("chat.scroll.body") // swiftlint:disable:this redundant_discardable_let
        ScrollView {
            ChatTranscriptRows(model: model, scroll: scroll, router: router, connectionIsSlow: connectionIsSlow)
        }
        .scrollPosition($scroll.position)
        .contentMargins(.top, max(0, chrome.bottom - chrome.top) + ChatMetrics.composerClearance, for: .automatic)
        .contentMargins(.bottom, max(0, chrome.top - chrome.bottom), for: .automatic)
        .onGeometryChange(for: EdgeInsets.self, of: \.safeAreaInsets) { chrome = $0 }
        .newestFirst()
        .overlay { ChatOpeningOverlay(model: model) }
        .scrollDismissesKeyboard(.interactively)
        .scrollEdgeEffectHidden(true, for: .all)
        .safeAreaInset(edge: .top, spacing: 0) { TeachBanner(model: teach, surface: .chat) }
        .safeAreaInset(edge: .top, spacing: 0) { ChatAutoApproveBanner(model: model) }
        .teachPresentations(teach, surface: .chat)
        .onScrollGeometryChange(for: ChatViewport.self, of: ChatViewport.init) { old, new in
            scroll.observe(new, tracksOpen: model.isOpenWindow)
            if new.contentHeight > old.contentHeight { scroll.contentGrew() }
        }
        .onScrollPhaseChange { _, phase in scroll.observe(phase) }
        .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.01) { scroll.visibleRowsChanged($0) }
        .onChange(of: chrome) { scroll.contentGrew() }
        .modifier(ChatRowsSync(model: model, scroll: scroll))
        .modifier(ChatOlderPaging(model: model, scroll: scroll))
        .modifier(ChatScreenAccessibility(model: model))
        .paneOverflowProbe("chat.pane")
        .overlay(alignment: .bottom) {
            if scroll.showsJumpButton, !model.isFinding {
                ChatJumpToNewest(scroll: scroll)
                    .padding(.bottom, 4)
                    .transition(jumpButtonTransition)
            }
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.25, bounce: 0), value: scroll.showsJumpButton)
        .modifier(ChatFindReveal(model: model, scroll: scroll))
        .task(id: model.connection) {
            connectionIsSlow = false
            guard model.connection != .live else { return }
            try? await Task.sleep(for: model.connection == .reconnecting ? Self.reconnectingNoticeDelay : Self.catchUpNoticeDelay)
            guard !Task.isCancelled else { return }
            connectionIsSlow = model.connection != .live
        }
    }

    private static let reconnectingNoticeDelay = Duration.seconds(1)
    private static let catchUpNoticeDelay = LoadingPolicy.silentWindow

    private var jumpButtonTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .scale(scale: 0.9).combined(with: .opacity),
            removal: .scale(scale: 0.9).combined(with: .opacity).animation(.easeIn(duration: 0.17))
        )
    }
}

private struct ChatTranscriptRows: View {
    let model: ChatModel
    let scroll: ChatScrollController
    let router: AppRouter
    let connectionIsSlow: Bool

    var body: some View {
        let _ = PalPerf.event("chat.list.body") // swiftlint:disable:this redundant_discardable_let
        let source = model.rowContextSource
        let ink = BubblePalette.ink(accent: source.accent)
        LazyVStack(alignment: .leading, spacing: 0) {
            footer(ink: ink)
                .chatListRow()
                .newestFirst()
            ForEach(model.rowsNewestFirst) { row in
                ChatRowView(row: row, context: source.context(for: row), model: model) { link in
                    router.push(.botThread(BotThreadRoute(
                        botName: model.bot.name,
                        threadID: link.threadID,
                        focusExchangeID: link.exchangeID
                    )))
                }
                .equatable()
                .chatListRow()
                .newestFirst()
                .background { ChatPinProbe(id: row.id, scroll: scroll, slot: scroll.pinSlots.slot(for: row.id)) }
            }
            if !model.rows.isEmpty {
                OlderHistoryRow(state: model.olderHistory, ink: ink) { model.wantOlder() }
                    .chatListRow()
                    .newestFirst()
                    .padding(.bottom, 8)
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
        if model.isRunning, !model.hasPendingPrompt {
            ChatWorkingRow(status: model.workingStatus, ink: ink, avatar: model.bot.spec)
                .padding(.top, ChatMetrics.senderSwitchGap)
        }
        if connectionIsSlow {
            connectionStatus
                .padding(.top, 12)
        }
    }

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

private struct ChatOpeningOverlay: View {
    let model: ChatModel

    var body: some View {
        if model.isOpening {
            DelayedReveal(after: ChatLoading.delay) {
                Text("Loading…")
                    .hermesText(.chatStatus)
                    .foregroundStyle(PalTokens.textSecondary)
                    .accessibilityIdentifier("chatLoading")
            }
        } else if model.rows.isEmpty, !model.isRunning {
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
