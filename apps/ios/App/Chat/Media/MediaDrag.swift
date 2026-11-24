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
private struct DragHandoff: @unchecked Sendable {
    let progress: Progress
    let completion: (URL?, Bool, (any Error)?) -> Void
}

nonisolated enum MediaDrag {
    static func provider(for media: MediaReference, source: any MediaAssetSource, staging: MediaDragStaging, ready: URL? = nil) -> NSItemProvider {
        if let ready, FileManager.default.fileExists(atPath: ready.path), let provider = NSItemProvider(contentsOf: ready) {
            return provider
        }
        let provider = NSItemProvider()
        provider.suggestedName = MediaDownloads.safeFileName(media.name)
        let type = UTType(filenameExtension: (media.name as NSString).pathExtension) ?? .movie
        provider.registerFileRepresentation(for: type, visibility: .all, openInPlace: false) { completion in
            let handoff = DragHandoff(progress: Progress(totalUnitCount: 100), completion: completion)
            let task = Task {
                do {
                    let file = try await staging.stage(media, from: source, limit: MediaLimits.downloadBytes) { update in
                        handoff.progress.completedUnitCount = Int64((update.fraction ?? 0) * 100)
                    }
                    handoff.completion(file, false, nil)
                } catch {
                    handoff.completion(nil, false, error)
                }
            }
            handoff.progress.cancellationHandler = { task.cancel() }
            return handoff.progress
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
