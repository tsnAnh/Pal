#if os(macOS)
import PalChat
import PalDesign
import SwiftUI

struct MacDocumentViewerHost: View {
    let model: ChatModel
    let attach: ComposerAttachActions
    let sent: () -> Void

    var body: some View {
        if let state = model.documentViewer {
            MacDocumentViewer(model: model, state: state, attach: attach, sent: sent)
                .environment(\.chatFileActions, model.fileActions)
        }
    }
}

private struct MacDocumentViewer: View {
    let model: ChatModel
    let state: DocumentViewerState
    let attach: ComposerAttachActions
    let sent: () -> Void

    @State private var composer = ViewerComposerState()
    @State private var dictation = DictationController()
    @State private var saved: ViewerSavedDocument?
    @FocusState private var composerFocused: Bool
    @FocusState private var viewerFocused: Bool

    private var downloadable: Data? { saved?.id == state.file.id ? saved?.data : nil }

    var body: some View {
        ViewerShell(
            title: state.title,
            actions: DocumentViewerState.actions,
            disabled: downloadable == nil ? [.download] : [],
            perform: perform
        ) {
            ViewerDocumentStage(state: state, saved: $saved) { model.openFile($0) }
                .id(state.file.id)
        } composer: {
            composerView
        }
        .focusable()
        .focused($viewerFocused)
        .focusEffectDisabled()
        .onAppear { viewerFocused = true }
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
            removeAttachment: { model.removeAttachment($0) },
            attachPhotos: attach.photos,
            attachCapture: attach.capture,
            attach: attach.intake,
            prompt: composer.placeholder(title: state.title),
            clearGlass: true
        )
        .frame(maxWidth: 680)
    }

    private func perform(_ action: ViewerAction) {
        switch action {
        case .download:
            if let downloadable { DocumentActions.save(downloadable, suggestedName: state.file.name) }
        case .close:
            dictation.stop()
            model.closeDocumentViewer()
        case .edit:
            break
        }
    }

    private func submit() {
        dictation.stop()
        model.dismissError()
        model.sendFromDocumentViewer(DocumentViewerSend.body(file: state.file, draft: composer.draft) ?? "")
        sent()
    }
}

private struct ViewerSavedDocument {
    let id: String
    let data: Data
}

private enum DocumentPhase {
    case loading
    case ready(ViewerDocument)
    case failed(String)
}

private struct ViewerDocumentStage: View {
    let state: DocumentViewerState
    @Binding var saved: ViewerSavedDocument?
    let openFile: (FileReference) -> Void

    @Environment(\.chatFileActions) private var actions
    @State private var phase = DocumentPhase.loading
    @State private var attempt = 0

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: attempt) { await load() }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(state.accessibilityName))
            .accessibilityIdentifier("documentViewerContent")
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            ViewerDocumentSkeleton()
        case .failed(let message):
            failure(message)
        case .ready(let document):
            ViewerDocumentPage(document: document, route: route)
        }
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 10) {
            PalIcon("doc.badge.ellipsis", ink: .secondary).font(.system(size: 32))
            Text("This file couldn't be loaded.")
            Text(message).font(.system(size: 12))
            Button { attempt += 1 } label: {
                Text("Retry")
                    .font(.system(size: 13))
                    .foregroundStyle(PalTokens.textPrimary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .palClearGlass(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("documentViewerRetry")
        }
        .multilineTextAlignment(.center)
        .foregroundStyle(PalTokens.textSecondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("documentViewerFailed")
    }

    private func route(_ url: URL) -> OpenURLAction.Result {
        switch DocumentLink.classify(url, from: state.file, chatFiles: state.chatFiles) {
        case .chatFile(let file):
            openFile(file)
            return .handled
        case .web:
            return .systemAction
        case .sameDocument, .unreachable:
            return .handled
        }
    }

    private func load() async {
        guard let actions else {
            phase = .failed(String(localized: "Files aren't available here."))
            return
        }
        phase = .loading
        saved = nil
        let state = state
        do {
            let data = try await actions.load(state.file)
            let document = await Task.detached(priority: .userInitiated) {
                ViewerDocument(data: data, kind: state.kind, file: state.file, chatFiles: state.chatFiles)
            }.value
            phase = .ready(document)
            saved = ViewerSavedDocument(id: state.file.id, data: data)
        } catch is CancellationError {
        } catch {
            phase = .failed(ImageLoadFailure(describing: error).reason)
        }
    }
}

private struct ViewerDocumentPage: View {
    let document: ViewerDocument
    let route: (URL) -> OpenURLAction.Result

    private static let columnWidth: CGFloat = 680

    var body: some View {
        switch document.body {
        case .empty:
            Text("This file is empty.")
                .foregroundStyle(PalTokens.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("documentViewerEmpty")
        case .markdown(let items):
            markdown(items)
        case .plainText(let chunks):
            plainText(chunks)
        }
    }

    private func markdown(_ items: [MarkdownLayoutItem]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(items) { item in
                    MarkdownItemView(item: item)
                        .equatable()
                }
                if let note = document.note { ViewerDocumentNote(text: note) }
            }
            .textSelection(.enabled)
            .environment(\.openURL, OpenURLAction(handler: route))
            .frame(maxWidth: Self.columnWidth, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("documentViewerMarkdown")
    }

    private func plainText(_ chunks: [DocumentTextChunk]) -> some View {
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(chunks) { chunk in
                    Text(chunk.text)
                        .font(RichCode.font)
                        .foregroundStyle(PalTokens.textPrimary)
                        .fixedSize(horizontal: true, vertical: false)
                }
                if let note = document.note { ViewerDocumentNote(text: note).padding(.top, 8) }
            }
            .textSelection(.enabled)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
        .accessibilityIdentifier("documentViewerPlainText")
    }
}

private struct ViewerDocumentNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(PalTokens.textSecondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(PalTokens.chipFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityIdentifier("documentViewerNote")
    }
}

private struct ViewerDocumentSkeleton: View {
    private static let trailing: [CGFloat] = [260, 0, 0, 60, 0, 120, 240, 0, 40]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(Self.trailing.enumerated()), id: \.offset) { index, trailing in
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(PalTokens.selected)
                    .frame(height: index == 0 ? 22 : 12)
                    .padding(.trailing, trailing)
            }
        }
        .frame(maxWidth: 680, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityLabel(Text("Loading document"))
        .accessibilityIdentifier("documentViewerLoading")
    }
}
#endif
