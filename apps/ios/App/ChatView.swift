import PalChat
import PalDesign
import PalDiagnostics
import PalRoster
import SwiftUI

struct ChatView: View {
    @State var model: ChatModel
    @State var draft = ""
    @State var dictation = DictationController()
    @State var isVoiceModePresented = false
    @LazyState var scroll: ChatScrollController
    @FocusState var composerFocused: Bool
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    let teach: TeachModel
    let router: AppRouter

    @Environment(\.hermesTheme) var theme
    @Environment(\.scenePhase) private var scenePhase

    init(model: ChatModel, teach: TeachModel, router: AppRouter) {
        _model = State(initialValue: model)
        _scroll = LazyState { ChatScrollController(layout: model.layout) }
        self.teach = teach
        self.router = router
    }

    var body: some View {
        let _ = PalPerf.event("chat.view.body") // swiftlint:disable:this redundant_discardable_let
        ChatTranscriptList(model: model, scroll: scroll, teach: teach, router: router)
            .palSafeAreaBar(edge: .bottom) {
                ChatBottomBar(
                    model: model,
                    router: router,
                    scroll: scroll,
                    dictation: dictation,
                    draft: $draft,
                    focused: $composerFocused,
                    isVoiceModePresented: $isVoiceModePresented
                )
                .chatColumn()
                .paneOverflowProbe("chat.composer")
                .iOSOnly { $0.ignoresSafeArea(.container, edges: .bottom) }
            }
            .iOSOnly { chat in
                chat
                    .palPrincipalToolbarItem { ChatTitleButton(model: model, router: router) }
                    .toolbar {
                        ToolbarItem(placement: .trailingBar) {
                            ChatOptionsMenu(model: model, router: router, focused: $composerFocused)
                        }
                    }
                    .toolbarTitleDisplayMode(.inline)
            }
            .macChatChrome(
                model: model,
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
            .messageMenuPresenter().composerActivity(focused: composerFocused)
            .typeToFocusComposer(draft: $draft, focused: $composerFocused) {
                model.suspendsTypeToFocus || isVoiceModePresented || router.sheet != nil
            }
            .task { model.start() }
            .onDisappear {
                dictation.stop()
                model.stop()
            }
            .onChange(of: scenePhase) { _, phase in
                model.setForeground(phase != .background)
                if phase != .active { model.markViewed() }
            }
            .fullCover(isPresented: $isVoiceModePresented) {
                VoiceModeView(model: model) { isVoiceModePresented = false }
            }
            .imageViewerPresentation(model: model, attach: model.attachActions) { scroll.jumpToBottom(animated: !reduceMotion) }
            .macSheet(item: $model.filePreview, size: .full) { file in
                FilePreviewSheet(file: file).environment(\.chatFileActions, model.fileActions)
            }
            .modifier(ChatBotScope(model: model, intake: model.attachIntake))
    }
}
