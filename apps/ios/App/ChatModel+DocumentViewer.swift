import Foundation
import PalChat

extension ChatModel {
    func openFile(_ file: FileReference) {
        guard case .viewer = FileOpenRoute(fileName: file.name, viewerShowsDocuments: Self.viewerShowsDocuments),
              let state = DocumentViewerState(file: file, chatFiles: rows.flatMap(\.files))
        else {
            filePreview = file
            return
        }
        documentViewer = state
    }

    func closeDocumentViewer() {
        documentViewer = nil
    }

    func sendFromDocumentViewer(_ text: String) {
        documentViewer = nil
        send(text)
    }

    #if os(macOS)
    private static let viewerShowsDocuments = true
    #else
    private static let viewerShowsDocuments = false
    #endif
}
