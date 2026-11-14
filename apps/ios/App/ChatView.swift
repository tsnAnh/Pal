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
    @State private var isNearBottom = true
    @State private var scrollPosition = ScrollPosition(edge: .bottom)
    @State private var shownRowLimit = ChatView.rowWindow
    @State private var pinnedToBottom = true
    @State private var connectionIsSlow = false
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
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(shownRows) { shown in
                        let row = shown.row
                        ChatRowView(row: row, previous: shown.previous, model: model) { link in
                            router.push(.botThread(BotThreadRoute(
                                botName: model.bot.name,
                                threadID: link.threadID,
                                focusExchangeID: link.exchangeID
                            )))
                        }
                        .id(row.id)
                    }
                    statusLine
                }
                .padding(.horizontal, ChatMetrics.edgeMargin)
                .padding(.top, 8)
                .chatColumn()
            }
            .scrollPosition($scrollPosition)
            .defaultScrollAnchor(.bottom)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .scrollDismissesKeyboard(.interactively)
            .scrollEdgeEffectHidden(true, for: .top)
            .overlay(alignment: .top) { topFade }
            .safeAreaInset(edge: .top, spacing: 0) { TeachBanner(model: teach, surface: .chat) }
            .safeAreaInset(edge: .top, spacing: 0) { AutoApproveBanner(sessionID: model.bot.conversationID) }
            .teachPresentations(teach, surface: .chat)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.visibleRect.maxY >= geometry.contentSize.height - 120
            } action: { _, nearBottom in
                isNearBottom = nearBottom
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top < 600
            } action: { _, nearTop in
                if nearTop, !pinnedToBottom { revealOlderRows() }
            }
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { _, _ in
                if pinnedToBottom { scrollPosition.scrollTo(edge: .bottom) }
            }
            .onScrollPhaseChange { oldPhase, newPhase, context in
                guard newPhase == .idle, oldPhase == .interacting || oldPhase == .decelerating else { return }
                let geometry = context.geometry
                pinnedToBottom = geometry.contentSize.height + geometry.contentInsets.bottom - geometry.visibleRect.maxY < 40
            }
            .accessibilityIdentifier("chatScreen")
            .overlay(alignment: .bottom) {
                if !isNearBottom {
                    ScrollToBottomButton { scrollToBottom() }
                        .padding(.bottom, 10)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.2), value: isNearBottom)
            .safeAreaBar(edge: .bottom) { bottomBar().chatColumn() }
            #if os(macOS)
            .safeAreaBar(edge: .top) {
                MacChatHeader(bot: model.bot, activity: model.activity, mood: model.avatarMood, router: router)
            }
            #endif
            .onChange(of: model.currentFindRowID) { _, id in
                guard let id else { return }
                pinnedToBottom = false
                if let index = model.rows.firstIndex(where: { $0.id == id }) {
                    shownRowLimit = max(shownRowLimit, model.rows.count - index)
                }
                withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
            }
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
    private var statusLine: some View {
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

    private static let rowWindow = 60
    private static let reconnectingNoticeDelay = Duration.seconds(1)
    private static let catchUpNoticeDelay = LoadingPolicy.silentWindow

    private struct ShownRow: Identifiable {
        let row: ChatRow
        let previous: ChatRow?
        var id: String { row.id }
    }

    private var shownRows: [ShownRow] {
        let rows = model.rows
        return (max(0, rows.count - shownRowLimit)..<rows.count).map { index in
            ShownRow(row: rows[index], previous: index > 0 ? rows[index - 1] : nil)
        }
    }

    private func revealOlderRows() {
        if shownRowLimit < model.rows.count {
            shownRowLimit += Self.rowWindow
            return
        }
        guard model.hasOlderHistory, !model.isLoadingOlder, let anchor = model.rows.first?.id else { return }
        Task {
            let before = model.rows.count
            guard await model.loadOlder() else { return }
            shownRowLimit += model.rows.count - before
            scrollPosition.scrollTo(id: anchor, anchor: .top)
        }
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
                scrollToBottom()
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

    private func scrollToBottom() {
        pinnedToBottom = true
        withAnimation(.easeOut(duration: 0.2)) { scrollPosition.scrollTo(edge: .bottom) }
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
