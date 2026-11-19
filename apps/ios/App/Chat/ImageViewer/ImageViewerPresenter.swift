import PalChat
import PhotosUI
import SwiftUI

struct ComposerAttachActions {
    let photos: ([PhotosPickerItem]) -> Void
    let capture: (PlatformImage) -> Void
    let imageData: ImageDataHandler
    let files: FilesHandler
}

extension View {
    func imageViewerPresentation(model: ChatModel, attach: ComposerAttachActions, sent: @escaping () -> Void) -> some View {
        #if os(iOS)
        fullCover(isPresented: Binding(get: { model.imageViewer != nil }, set: { if !$0 { model.imageViewer = nil } })) {
            ChatImageViewer(model: model).environment(\.chatImageLoader, model.imageLoader)
        }
        #else
        overlay { MacImageViewerHost(model: model, attach: attach, sent: sent) }
        #endif
    }
}
