import HermesChat
import HermesDesign
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

typealias FilesHandler = @MainActor @Sendable ([URL]) -> Void
typealias ImageDataHandler = @MainActor @Sendable (Data) -> Void

extension View {
    func attachmentIntake(handlesPaste: Bool = true, files: @escaping FilesHandler, imageData: @escaping ImageDataHandler) -> some View {
        modifier(AttachmentIntakeModifier(handlesPaste: handlesPaste, files: files, imageData: imageData))
    }
}

private struct AttachmentIntakeModifier: ViewModifier {
    let handlesPaste: Bool
    let files: FilesHandler
    let imageData: ImageDataHandler

    @State private var isTargeted = false
    @Environment(\.hermesTheme) private var theme

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .onDrop(of: [.fileURL, .image], isTargeted: $isTargeted) { providers in
                AttachmentIntake.receive(providers, files: files, imageData: imageData)
            }
            .onPasteCommand(of: handlesPaste ? [.fileURL, .image] : []) { providers in
                _ = AttachmentIntake.receive(providers, files: files, imageData: imageData)
            }
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: HermesMetrics.cardRadius, style: .continuous)
                        .strokeBorder(Color(theme.palette.primaryBadge), lineWidth: 2)
                        .padding(2)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("composerDropTarget")
                }
            }
        #else
        if handlesPaste, #available(iOS 27.0, *) {
            content
                .pasteDestination(for: Data.self) { datas in
                    datas.forEach { imageData($0) }
                } validator: { datas in
                    datas.filter(AttachmentIntake.isImage)
                }
        } else {
            content
        }
        #endif
    }
}

enum AttachmentIntake {
    nonisolated static func isImage(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { return false }
        return true
    }

    #if os(macOS)
    @MainActor static func receive(_ providers: [NSItemProvider], files: @escaping FilesHandler, imageData: @escaping ImageDataHandler) -> Bool {
        let usable = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) || $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
        }
        guard !usable.isEmpty else { return false }
        Task {
            var urls: [URL] = []
            var images: [Data] = []
            for provider in usable {
                if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier), let url = await fileURL(from: provider) {
                    urls.append(url)
                } else if let data = await Self.imageData(from: provider) {
                    images.append(data)
                }
            }
            await MainActor.run {
                if !urls.isEmpty { files(urls) }
                images.forEach { imageData($0) }
            }
        }
        return true
    }

    @MainActor private static func fileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url?.isFileURL == true ? url : nil)
            }
        }
    }

    @MainActor private static func imageData(from provider: NSItemProvider) async -> Data? {
        await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }
    #endif
}
