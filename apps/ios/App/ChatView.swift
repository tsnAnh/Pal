import HermesDesign
import HermesProtocol
import HermesRoster
import PhotosUI
import SwiftUI

struct ChatView: View {
    @State private var model: ChatModel
    @State private var draft = ""
    @State private var dictation = DictationController()
    @State private var isVoiceModePresented = false
    @State private var isNearBottom = true
    @State private var scrollPosition = ScrollPosition(edge: .bottom)
    @FocusState private var composerFocused: Bool

    let router: AppRouter

    @Environment(\.hermesTheme) private var theme
    @Environment(\.scenePhase) private var scenePhase

    init(model: ChatModel, router: AppRouter) {
        _model = State(initialValue: model)
        self.router = router
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: ChatMetrics.rowSpacing) {
                    ForEach(model.rows) { row in
                        ChatRowView(row: row, model: model) { link in
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
            }
            .scrollPosition($scrollPosition)
            .defaultScrollAnchor(.bottom)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .scrollDismissesKeyboard(.interactively)
            .scrollEdgeEffectStyle(.soft, for: .top)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.visibleRect.maxY >= geometry.contentSize.height - 120
            } action: { _, nearBottom in
                isNearBottom = nearBottom
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
            .safeAreaBar(edge: .bottom) { bottomBar() }
            .onChange(of: model.isCatchingUp) { _, catchingUp in
                if catchingUp, isNearBottom { scrollToBottom() }
            }
            .onChange(of: model.currentFindRowID) { _, id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                BotCapsule(bot: model.bot, activity: model.activity, mood: model.avatarMood)
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .topBarTrailing) {
                menu
            }
        }
        .toolbarTitleDisplayMode(.inline)
        .background(Color(theme.palette.canvas))
        .task { model.start() }
        .onDisappear {
            dictation.stop()
            model.stop()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { model.markViewed() }
        }
        .fullScreenCover(isPresented: $isVoiceModePresented) {
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

    private var dotColor: Color {
        model.chatAccent?.accent ?? Color(theme.palette.chipSelectedFill)
    }

    @ViewBuilder
    private func bottomBar() -> some View {
        if model.isFinding {
            FindBar(model: model)
        } else {
            ChatComposer(
                botName: model.bot.displayName,
                accent: model.chatAccent,
                attachments: model.attachments,
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
                attachFiles: { urls in Task { await loadFiles(urls) } }
            )
        }
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

    private func stage(image: UIImage) async {
        do {
            let upload = try await Task.detached { try AttachmentPreparer.prepareImage(from: image) }.value
            model.attachPhoto(upload)
        } catch {
            model.reportAttachmentFailure(String(localized: "That photo couldn't be prepared."))
        }
    }

    private func loadFiles(_ urls: [URL]) async {
        for url in urls {
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
        .glassEffect(.regular.tint(Color(theme.palette.glassCapsuleFill).opacity(0.55)), in: .capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(bot.displayName))
        .accessibilityValue(Text(activity.accessibilityValue))
        .accessibilityIdentifier("chatTitle")
    }
}
