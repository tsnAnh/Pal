import SwiftUI
import UniformTypeIdentifiers

typealias FilesHandler = @MainActor @Sendable ([URL]) -> Void
typealias ImageDataHandler = @MainActor @Sendable (Data) -> Void

extension View {
    func attachmentIntake(files: @escaping FilesHandler, imageData: @escaping ImageDataHandler) -> some View {
        #if os(macOS)
        dropDestination(for: URL.self) { urls, _ in
            let fileURLs = urls.filter(\.isFileURL)
            guard !fileURLs.isEmpty else { return false }
            files(fileURLs)
            return true
        }
        .onPasteCommand(of: [.fileURL, .image]) { providers in
            for provider in providers {
                AttachmentIntake.load(provider, files: files, imageData: imageData)
            }
        }
        #else
        self
        #endif
    }
}

#if os(macOS)
private enum AttachmentIntake {
    static func load(_ provider: NSItemProvider, files: @escaping FilesHandler, imageData: @escaping ImageDataHandler) {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = provider.loadTransferable(type: URL.self) { result in
                guard case .success(let url) = result, url.isFileURL else { return }
                Task { @MainActor in files([url]) }
            }
        } else {
            _ = provider.loadTransferable(type: Data.self) { result in
                guard case .success(let data) = result else { return }
                Task { @MainActor in imageData(data) }
            }
        }
    }
}
#endif
