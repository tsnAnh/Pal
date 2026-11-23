import PalChat
import PhotosUI
import SwiftUI

struct ComposerAttachActions {
    let photos: ([PhotosPickerItem]) -> Void
    let capture: (PlatformImage) -> Void
    let intake: IntakeHandler
}

extension View {
    func imageViewerPresentation(model: ChatModel, attach: ComposerAttachActions, sent: @escaping () -> Void) -> some View {
        modifier(ViewerPresentation(model: model, attach: attach, sent: sent))
    }
}

private struct ViewerPresentation: ViewModifier {
    let model: ChatModel
    let attach: ComposerAttachActions
    let sent: () -> Void

    @State private var media: MediaViewerState?

    func body(content: Content) -> some View {
        let resolver = model.mediaResolver
        let wired = content
            .environment(\.mediaPreviewResolver, resolver)
            .environment(\.mediaOpener) { reference, rowID in open(reference, inRow: rowID) }
        #if os(iOS)
        wired
            .fullCover(isPresented: Binding(get: { media != nil }, set: { if !$0 { closeMedia() } })) {
                if let state = Binding($media) {
                    MediaPlayerCover(state: state, source: resolver.source, close: closeMedia)
                }
            }
            .fullCover(isPresented: Binding(get: { model.imageViewer != nil }, set: { if !$0 { model.imageViewer = nil } })) {
                ChatImageViewer(model: model).environment(\.chatImageLoader, model.imageLoader)
            }
        #else
        wired.overlay {
            MacImageViewerHost(model: model, attach: attach, sent: sent)
            MacDocumentViewerHost(model: model, attach: attach, sent: sent)
            MacMediaViewerHost(viewer: $media, source: resolver.source)
        }
        #endif
    }

    private func open(_ reference: MediaReference, inRow rowID: String) {
        let rows = model.rows.map { ConversationMediaRow(rowID: $0.id, media: MediaReference.split($0.files).media) }
        media = ConversationMediaList.viewer(opening: reference, inRow: rowID, rows: rows)
    }

    private func closeMedia() {
        for file in MediaViewerState.close(&media) { MediaDownloads.remove(file) }
    }
}
