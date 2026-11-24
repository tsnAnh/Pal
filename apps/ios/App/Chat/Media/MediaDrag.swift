import PalChat
import SwiftUI
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

struct MediaTileDrag: ViewModifier {
    let media: MediaReference
    let staging: MediaDragStaging

    @Environment(\.mediaPreviewResolver) private var resolver

    func body(content: Content) -> some View {
        #if os(macOS)
        if let source = resolver?.source {
            content.onDrag { MediaDrag.provider(for: media, source: source, staging: staging) }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

#if os(macOS)
nonisolated enum MediaDrag {
    static func provider(for media: MediaReference, source: any MediaAssetSource, staging: MediaDragStaging, ready: URL? = nil) -> NSItemProvider {
        if let ready, FileManager.default.fileExists(atPath: ready.path), let provider = NSItemProvider(contentsOf: ready) {
            return provider
        }
        let provider = NSItemProvider()
        provider.suggestedName = MediaDownloads.safeFileName(media.name)
        let type = UTType(filenameExtension: (media.name as NSString).pathExtension) ?? .movie
        provider.registerFileRepresentation(for: type, visibility: .all, openInPlace: false) { completion in
            let progress = Progress(totalUnitCount: 100)
            let task = Task {
                do {
                    let file = try await staging.stage(media, from: source, limit: MediaLimits.downloadBytes) { update in
                        progress.completedUnitCount = Int64((update.fraction ?? 0) * 100)
                    }
                    completion(file, false, nil)
                } catch {
                    completion(nil, false, error)
                }
            }
            progress.cancellationHandler = { task.cancel() }
            return progress
        }
        return provider
    }

    static func copyable(_ file: URL) -> [NSItemProvider] {
        let manager = FileManager.default
        let folder = MediaDownloads.directory.appending(path: "copied-\(UUID().uuidString)", directoryHint: .isDirectory)
        let target = folder.appending(path: file.lastPathComponent, directoryHint: .notDirectory)
        let linked = (try? manager.createDirectory(at: folder, withIntermediateDirectories: true)) != nil
            && (try? manager.linkItem(at: file, to: target)) != nil
        return [NSItemProvider(object: (linked ? target : file) as NSURL)]
    }
}
#endif
