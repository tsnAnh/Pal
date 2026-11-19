import PalChat
import PalConnect
import PalDesign
import PalProtocol
import PalRoster
import PhotosUI
import SwiftUI

struct ChatView: View {
    @State private var model: ChatModel
    @State private var draft = ""
    @State private var dictation = DictationController()
    @State private var isVoiceModePresented = false
    @State private var scroll = ChatScrollController()
    @State private var connectionIsSlow = false
    @State private var chrome = EdgeInsets()
    @FocusState private var composerFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let teach: TeachModel
    let router: AppRouter

    @Environment(\.hermesTheme) private var theme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(SettingsHub.self) private var hub
    @Environment(ActionAutoApprove.self) private var autoApprove
    #if os(macOS)
    @Environment(MacShell.self) private var shell
    #endif

    init(model: ChatModel, teach: TeachModel, router: AppRouter) {
        _model = State(initialValue: model)
        self.teach = teach
        self.router = router
    }

    var body: some View {
        chat
            .attachmentIntake(
                handlesPaste: false,
                files: { urls in Task { await loadFiles(urls) } },
                imageData: { data in Task { await stage(imageData: data) } }
            )
    }

    private var chat: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                let accent = model.chatAccent
                footer
                    .newestFirst()
                ForEach(model.rowsNewestFirst) { row in
                    ChatRowView(row: row, context: model.rowContext(for: row, accent: accent), model: model) { link in
                        router.push(.botThread(BotThreadRoute(
                            botName: model.bot.name,
                            threadID: link.threadID,
                            focusExchangeID: link.exchangeID
                        )))
                    }
                    .equatable()
                    .newestFirst()
                    .background { ChatPinProbe(id: row.id, scroll: scroll) }
                }
                if !model.rows.isEmpty {
                    OlderHistoryRow(state: model.olderHistory, ink: ink) { model.wantOlder() }
                        .newestFirst()
                        .padding(.bottom, 8)
                }
            }
            .scrollTargetLayout()
            .coordinateSpace(.named(ChatScrollController.contentSpace))
            .padding(.horizontal, ChatMetrics.edgeMargin)
            .chatColumn()
        }
        .scrollPosition($scroll.position)
        .contentMargins(.top, max(0, chrome.bottom - chrome.top), for: .automatic)
        .contentMargins(.bottom, max(0, chrome.top - chrome.bottom), for: .automatic)
        .onGeometryChange(for: EdgeInsets.self, of: \.safeAreaInsets) { chrome = $0 }
        .newestFirst()
        .mask { edgeFade }
        .overlay { openingState }
        .scrollDismissesKeyboard(.interactively)
        .scrollEdgeEffectHidden(true, for: .all)
        .safeAreaInset(edge: .top, spacing: 0) { TeachBanner(model: teach, surface: .chat) }
        .safeAreaInset(edge: .top, spacing: 0) { AutoApproveBanner(sessionID: model.bot.conversationID) }
        .teachPresentations(teach, surface: .chat)
        .onScrollGeometryChange(for: ChatViewport.self, of: ChatViewport.init) { old, new in
            scroll.observe(new, tracksOpen: model.isOpenWindow)
            if new.contentHeight > old.contentHeight { scroll.contentGrew() }
        }
        .onScrollPhaseChange { _, phase in scroll.observe(phase) }
        .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.01) { scroll.visibleRowsChanged($0) }
        .onChange(of: chrome) { scroll.contentGrew() }
        .onChange(of: model.rowIDs, initial: true) { _, ids in scroll.rowsChanged(ids) }
        .task(id: OlderDemand(wants: scroll.wantsOlder, state: model.olderHistory)) {
            guard scroll.wantsOlder, model.olderHistory.canLoad else { return }
            while !Task.isCancelled {
                model.wantOlder()
                try? await Task.sleep(for: Self.olderDemandInterval)
            }
        }
        .accessibilityIdentifier("chatScreen")
        .accessibilityValue(Text(historySummary))
        .overlay(alignment: .bottom) {
            if scroll.showsJumpButton, !model.isFinding {
                ScrollToBottomButton(newCount: scroll.unseen) { scroll.jumpToBottom(animated: !reduceMotion) }
                    .padding(.bottom, 4)
                    .transition(jumpButtonTransition)
            }
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.25, bounce: 0), value: scroll.showsJumpButton)
        .safeAreaBar(edge: .bottom) { bottomBar().chatColumn() }
        .onChange(of: model.currentFindRowID) { _, id in
            guard let id else { return }
            scroll.reveal(id)
        }
        .iOSOnly { chat in
            chat
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        Button { router.perform(.viewProfile, botName: model.bot.name) } label: {
                            BotCapsule(bot: model.bot, activity: model.activity, mood: model.avatarMood)
                        }
                        .buttonStyle(.plain)
                        .disabled(!router.supports(.viewProfile))
                        .accessibilityHint(Text("Shows this bot's profile"))
                        .accessibilityIdentifier("chatTitle")
                    }
                    .sharedBackgroundVisibility(.hidden)
                    ToolbarItem(placement: .trailingBar) {
                        menu
                    }
                }
                .toolbarTitleDisplayMode(.inline)
        }
        .macChatChrome(
            bot: model.bot,
            activity: model.activity,
            mood: model.avatarMood,
            router: router,
            find: {
                composerFocused = false
                model.beginFinding()
            },
            focusComposer: {
                model.endFinding()
                Task { composerFocused = true }
            }
        )
        .background(PlatformVariant.pick(mac: PalTokens.content, iOS: Color(theme.palette.canvas)))
        .messageMenuPresenter()
        .environment(\.chatInk, ink)
        .environment(\.focusComposer) {
            model.endFinding()
            composerFocused = true
        }
        .task { model.start() }
        .task(id: model.bot.conversationID) { await autoApprove.load(sessionID: model.bot.conversationID) }
        .task(id: model.connection) {
            connectionIsSlow = false
            guard model.connection != .live else { return }
            try? await Task.sleep(for: model.connection == .reconnecting ? Self.reconnectingNoticeDelay : Self.catchUpNoticeDelay)
            guard !Task.isCancelled else { return }
            connectionIsSlow = model.connection != .live
        }
        .onChange(of: model.pendingDraft, initial: true) { _, pending in
            guard let pending else { return }
            draft = pending
            model.clearPendingDraft()
            composerFocused = true
        }
        .onChange(of: model.replyTarget) { _, target in
            if target != nil { composerFocused = true }
        }
        .onDisappear {
            dictation.stop()
            model.stop()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { model.markViewed() }
        }
        .fullCover(isPresented: $isVoiceModePresented) {
            VoiceModeView(model: model) { isVoiceModePresented = false }
        }
        .fullCover(isPresented: Binding(get: { model.imageViewer != nil }, set: { if !$0 { model.imageViewer = nil } })) {
            ChatImageViewer(model: model).environment(\.chatImageLoader, model.imageLoader)
        }
        .sheet(item: $model.filePreview) { file in
            FilePreviewSheet(file: file).environment(\.chatFileActions, model.fileActions)
        }
    }

    @ViewBuilder
    private var footer: some View {
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
            ChatStatusLine(text: String(localized: "Reconnecting…"), systemImage: "clock")
                .accessibilityIdentifier("reconnectingIndicator")
        case .connecting, .live:
            if model.isCatchingUp {
                ChatStatusLine(text: String(localized: "Checking for new messages…"), systemImage: "clock")
                    .accessibilityIdentifier("chatStatusLine")
            }
        }
    }

    private static let reconnectingNoticeDelay = Duration.seconds(1)
    private static let catchUpNoticeDelay = LoadingPolicy.silentWindow
    private static let olderDemandInterval = Duration.milliseconds(250)

    private struct OlderDemand: Hashable {
        let wants: Bool
        let state: OlderHistory
    }

    private var historySummary: String {
        let count = String(localized: "\(model.rows.count) messages")
        return model.olderHistory == .loading ? count + ", " + String(localized: "loading earlier messages") : count
    }

    private var ink: Color { BubblePalette.ink(accent: model.chatAccent) }

    private var jumpButtonTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .scale(scale: 0.9).combined(with: .opacity),
            removal: .scale(scale: 0.9).combined(with: .opacity).animation(.easeIn(duration: 0.17))
        )
    }

    private var edgeFade: some View {
        GeometryReader { proxy in
            let insets = proxy.safeAreaInsets
            VStack(spacing: 0) {
                Color.clear
                    .frame(height: max(0, max(insets.top, ChatEdgeFade.topFloor) - ChatEdgeFade.feather / 2))
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: ChatEdgeFade.feather * 1.5)
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: ChatEdgeFade.feather)
                Color.clear
                    .frame(height: max(0, insets.bottom - ChatEdgeFade.feather))
            }
            .frame(width: proxy.size.width, height: proxy.size.height + insets.top + insets.bottom)
            .offset(y: -insets.top)
        }
    }

    @ViewBuilder
    private var openingState: some View {
        if model.isOpening {
            DelayedReveal(after: ChatEdgeFade.loadingDelay) {
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

    @ViewBuilder
    private func bottomBar() -> some View {
        if model.isFinding {
            FindBar(model: model)
        } else {
            VStack(spacing: 0) {
                if let notice = dictation.failure ?? model.sendError {
                    ComposerNotice(text: notice) {
                        dictation.dismissFailure()
                        model.dismissError()
                    }
                    .padding(.horizontal, ChatMetrics.edgeMargin)
                    .transition(.opacity)
                }
                if let notice = hub.usageNotice {
                    UsageBanner(notice: notice) {
                        reviewUsage()
                    } dismiss: {
                        hub.dismissUsageNotice()
                    }
                    .padding(.horizontal, ChatMetrics.edgeMargin)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                composer
            }
            .animation(.snappy(duration: 0.2), value: hub.usageNotice)
            .animation(.easeOut(duration: 0.2), value: dictation.failure ?? model.sendError)
            .task { await hub.refreshUsageIfStale() }
        }
    }

    private func reviewUsage() {
        #if os(macOS)
        shell.settingsSection = .usage
        router.present(.settings)
        #else
        router.presentSettings(route: .usage)
        #endif
    }

    private var composer: some View {
        ChatComposer(
            botName: model.bot.displayName,
            accent: model.chatAccent,
            answersQuestion: model.hasPendingClarify,
            attachments: model.attachments,
            slashItems: model.slashItems,
            loadSlashItems: { model.loadSlashItems() },
            fileRefResult: model.fileRefResult,
            loadFileRefs: { model.loadFileRefs(word: $0) },
            replyTarget: model.replyTarget,
            cancelReply: { model.cancelReply() },
            canSend: model.canSendAttachments,
            dictation: dictation,
            draft: $draft,
            focused: $composerFocused,
            send: {
                dictation.stop()
                model.dismissError()
                model.send(draft)
                draft = ""
                scroll.jumpToBottom(animated: !reduceMotion)
            },
            openVoiceMode: {
                dictation.stop()
                composerFocused = false
                isVoiceModePresented = true
            },
            removeAttachment: { model.removeAttachment($0) },
            attachPhotos: { items in Task { await loadPhotos(items) } },
            attachCapture: { image in Task { await stage(image: image) } },
            attachImageData: { data in Task { await stage(imageData: data) } },
            attachFiles: { urls in Task { await loadFiles(urls) } }
        )
    }

    private var menu: some View {
        Menu {
            if router.supports(.viewProfile) {
                Button { router.perform(.viewProfile, botName: model.bot.name) } label: {
                    Label("View Profile", systemImage: "person.crop.circle")
                }
                .accessibilityIdentifier("chatMenuViewProfile")
            }
            Button {
                composerFocused = false
                model.beginFinding()
            } label: {
                Label("Find in Chat", systemImage: "magnifyingglass")
            }
            .accessibilityIdentifier("chatMenuFind")
            if router.supports(.shareAsTemplate) {
                Button { router.perform(.shareAsTemplate, botName: model.bot.name) } label: {
                    Label("Share as Template…", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("chatMenuShareTemplate")
            }
        } label: {
            Image(systemName: "ellipsis")
                .accessibilityLabel(Text("Chat options"))
        }
        .tint(Color(theme.palette.textPrimary))
        .accessibilityIdentifier("chatMenuButton")
    }

    private func loadPhotos(_ items: [PhotosPickerItem]) async {
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                model.reportAttachmentFailure(String(localized: "That photo couldn't be loaded."))
                continue
            }
            await stage(imageData: data)
        }
    }

    private func stage(imageData data: Data) async {
        do {
            let upload = try await Task.detached { try AttachmentPreparer.prepareImage(from: data) }.value
            model.attachPhoto(upload)
        } catch {
            model.reportAttachmentFailure(String(localized: "That photo couldn't be prepared."))
        }
    }

    private func stage(image: PlatformImage) async {
        do {
            let upload = try await Task.detached { try AttachmentPreparer.prepareImage(from: image) }.value
            model.attachPhoto(upload)
        } catch {
            model.reportAttachmentFailure(String(localized: "That photo couldn't be prepared."))
        }
    }

    private func loadFiles(_ urls: [URL]) async {
        let items = DropIntake.classify(urls)
        if let message = DropIntake.rejectionMessage(for: items) { model.reportAttachmentFailure(message) }
        for item in items {
            let url: URL
            switch item {
            case .image(let accepted), .document(let accepted): url = accepted
            case .rejected: continue
            }
            do {
                let prepared = try await Task.detached { try AttachmentPreparer.prepareFile(at: url) }.value
                if prepared.isImage { model.attachPhoto(prepared.upload) } else { model.attachFile(prepared.upload, mime: prepared.mime) }
            } catch AttachmentError.tooLarge {
                model.reportAttachmentFailure(String(localized: "That file is too large to send."))
            } catch {
                model.reportAttachmentFailure(String(localized: "That file couldn't be read."))
            }
        }
    }
}

private extension View {
    func newestFirst() -> some View {
        scaleEffect(x: 1, y: -1, anchor: .center)
    }
}

private struct BotCapsule: View {
    @Environment(\.hermesTheme) private var theme

    let bot: BotRow
    let activity: BotActivity
    let mood: AvatarMood

    var body: some View {
        HStack(spacing: 9) {
            BotAvatarView(spec: bot.spec, size: ChatMetrics.headerAvatarSize, mood: mood)
                .opacity(activity.avatarOpacity)
            Text(bot.displayName)
                .hermesText(.botName)
                .foregroundStyle(Color(theme.palette.textPrimary))
                .lineLimit(1)
        }
        .padding(.horizontal, 13)
        .frame(height: ChatMetrics.headerButtonDiameter)
        .palGlass(Capsule(), interactive: true)
        .contentShape(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(bot.displayName))
        .accessibilityValue(Text(activity.accessibilityValue))
    }
}
