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

    let teach: TeachModel
    let router: AppRouter

    @Environment(\.hermesTheme) private var theme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(SettingsHub.self) private var hub
    @Environment(ActionAutoApprove.self) private var autoApprove
    #if os(macOS)
    @Environment(MacShell.self) private var shell
    #else
    @State private var messageMenu: MessageMenuRequest?
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
                footer
                    .newestFirst()
                ForEach(model.rows.reversed()) { row in
                    ChatRowView(row: row, model: model) { link in
                        router.push(.botThread(BotThreadRoute(
                            botName: model.bot.name,
                            threadID: link.threadID,
                            focusExchangeID: link.exchangeID
                        )))
                    }
                    .newestFirst()
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .scrollView).minY } action: { scroll.rowMoved(row.id, minY: $0) }
                }
                OlderHistoryRow(state: model.olderHistory) { model.wantOlder() }
                    .newestFirst()
                    .padding(.bottom, 8)
            }
            .scrollTargetLayout()
            .padding(.horizontal, ChatMetrics.edgeMargin)
            .chatColumn()
        }
        .scrollPosition($scroll.position)
        .contentMargins(.top, max(0, chrome.bottom - chrome.top), for: .automatic)
        .contentMargins(.bottom, max(0, chrome.top - chrome.bottom), for: .automatic)
        .onGeometryChange(for: EdgeInsets.self, of: \.safeAreaInsets) { chrome = $0 }
        .newestFirst()
        .scrollDismissesKeyboard(.interactively)
        .scrollEdgeEffectHidden(true, for: .all)
        .overlay(alignment: .top) { topFade }
        .safeAreaInset(edge: .top, spacing: 0) { TeachBanner(model: teach, surface: .chat) }
        .safeAreaInset(edge: .top, spacing: 0) { AutoApproveBanner(sessionID: model.bot.conversationID) }
        .teachPresentations(teach, surface: .chat)
        .onScrollGeometryChange(for: ChatViewport.self, of: ChatViewport.init) { old, new in
            scroll.observe(new)
            if new.contentHeight > old.contentHeight { scroll.contentGrew() }
        }
        .onScrollPhaseChange { _, phase in scroll.observe(phase) }
        .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.01) { scroll.visibleRowsChanged($0) }
        .onChange(of: chrome) { scroll.contentGrew() }
        .onChange(of: model.rows.map(\.id), initial: true) { _, ids in scroll.rowsChanged(ids) }
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
            if scroll.showsJumpButton {
                ScrollToBottomButton(newCount: scroll.unseen) { scroll.jumpToBottom() }
                    .padding(.bottom, 10)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.2), value: scroll.showsJumpButton)
        .safeAreaBar(edge: .bottom) { bottomBar().chatColumn() }
        #if os(macOS)
        .safeAreaBar(edge: .top) {
            MacChatHeader(bot: model.bot, activity: model.activity, mood: model.avatarMood, router: router)
        }
        #endif
        .onChange(of: model.currentFindRowID) { _, id in
            guard let id else { return }
            scroll.reveal(id)
        }
        #if os(iOS)
        .toolbar {
            ToolbarItem(placement: .principal) {
                BotCapsule(bot: model.bot, activity: model.activity, mood: model.avatarMood)
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .trailingBar) {
                menu
            }
        }
        .toolbarTitleDisplayMode(.inline)
        #else
        .macChatActions(
            find: {
                composerFocused = false
                model.beginFinding()
            },
            focusComposer: {
                model.endFinding()
                Task { composerFocused = true }
            }
        )
        #endif
        #if os(macOS)
        .background(PalTokens.content)
        #else
        .background(Color(theme.palette.canvas))
        .environment(\.presentMessageMenu) { messageMenu = $0 }
        .overlay { MessageMenuHost(request: $messageMenu) }
        #endif
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
        .alert(
            Text("Something went wrong"),
            isPresented: Binding(get: { model.sendError != nil }, set: { if !$0 { model.dismissError() } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.sendError ?? "")
        }
        .alert(
            Text("Dictation unavailable"),
            isPresented: Binding(get: { dictation.failure != nil }, set: { if !$0 { dictation.dismissFailure() } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(dictation.failure ?? "")
        }
    }

    @ViewBuilder
    private var footer: some View {
        if model.isRunning, !model.hasPendingPrompt {
            ChatWorkingRow(status: model.workingStatus, accent: model.chatAccent)
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
            ChatStatusLine(text: String(localized: "Reconnecting…"), dotColor: dotColor)
                .accessibilityIdentifier("reconnectingIndicator")
        case .connecting, .live:
            if model.isCatchingUp {
                ChatStatusLine(text: String(localized: "Checking for new messages…"), dotColor: dotColor)
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

    private var dotColor: Color {
        model.chatAccent?.accent ?? Color(theme.palette.chipSelectedFill)
    }

    @ViewBuilder
    private func bottomBar() -> some View {
        if model.isFinding {
            FindBar(model: model)
        } else {
            VStack(spacing: 0) {
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

    private var topFade: some View {
        #if os(macOS)
        ChatTopFade(color: PalTokens.content, height: MacMetrics.topBarHeight + 10)
            .ignoresSafeArea(.container, edges: .top)
        #else
        GeometryReader { proxy in
            ChatTopFade(color: Color(theme.palette.canvas), height: proxy.safeAreaInsets.top + 14)
                .ignoresSafeArea(.container, edges: .top)
        }
        .allowsHitTesting(false)
        #endif
    }

    private var composer: some View {
        ChatComposer(
            botName: model.bot.displayName,
            accent: model.chatAccent,
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
                model.send(draft)
                draft = ""
                scroll.jumpToBottom()
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
        .palGlass(Capsule(), interactive: false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(bot.displayName))
        .accessibilityValue(Text(activity.accessibilityValue))
        .accessibilityIdentifier("chatTitle")
    }
}
