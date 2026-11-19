#if os(macOS)
import PalChat
import PalDesign
import SwiftUI

struct MacImageViewerHost: View {
    let model: ChatModel
    let attach: ComposerAttachActions
    let sent: () -> Void

    var body: some View {
        if let state = model.imageViewer {
            MacImageViewer(model: model, state: state, attach: attach, sent: sent)
                .environment(\.chatImageLoader, model.imageLoader)
        }
    }
}

private struct MacImageViewer: View {
    let model: ChatModel
    let state: ImageViewerState
    let attach: ComposerAttachActions
    let sent: () -> Void

    @State private var composer = ViewerComposerState()
    @State private var dictation = DictationController()
    @State private var loaded: ViewerLoadedImage?
    @FocusState private var composerFocused: Bool
    @FocusState private var viewerFocused: Bool

    private var loadedImage: CGImage? { loaded?.id == state.current.id ? loaded?.image : nil }

    var body: some View {
        ViewerShell(
            title: state.title,
            actions: state.content.actions,
            disabled: loadedImage == nil ? [.download] : [],
            perform: perform
        ) {
            ViewerContentView(content: state.content, state: state, loaded: $loaded, step: step)
        } composer: {
            composerView
        }
        .focusable()
        .focused($viewerFocused)
        .focusEffectDisabled()
        .onAppear { viewerFocused = true }
        .onKeyPress(.leftArrow) {
            step(-1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            step(1)
            return .handled
        }
        .onKeyPress(.escape) {
            perform(.close)
            return .handled
        }
    }

    private var composerView: some View {
        ChatComposer(
            botName: model.bot.displayName,
            accent: model.chatAccent,
            answersQuestion: false,
            attachments: model.attachments,
            slashItems: model.slashItems,
            loadSlashItems: { model.loadSlashItems() },
            fileRefResult: model.fileRefResult,
            loadFileRefs: { model.loadFileRefs(word: $0) },
            replyTarget: nil,
            cancelReply: {},
            canSend: model.canSendAttachments,
            dictation: dictation,
            draft: $composer.draft,
            focused: $composerFocused,
            send: submit,
            openVoiceMode: nil,
            removeAttachment: { model.removeViewerAttachment($0) },
            attachPhotos: attach.photos,
            attachCapture: attach.capture,
            attachImageData: attach.imageData,
            attachFiles: attach.files,
            prompt: composer.placeholder(title: state.title),
            clearGlass: true
        )
        .frame(maxWidth: 680)
    }

    private func perform(_ action: ViewerAction) {
        switch action {
        case .edit:
            composer.edit(state.current)
            _ = model.stageViewerImage(state.current)
            composerFocused = true
        case .download:
            if let loadedImage { ImageActions.save(loadedImage, suggestedName: state.current.reference.name) }
        case .close:
            dictation.stop()
            model.closeImageViewer()
        }
    }

    private func step(_ delta: Int) {
        if delta < 0 { model.imageViewer?.goPrevious() } else { model.imageViewer?.goNext() }
    }

    private func submit() {
        dictation.stop()
        model.dismissError()
        model.sendFromViewer(composer)
        sent()
    }
}
#endif
