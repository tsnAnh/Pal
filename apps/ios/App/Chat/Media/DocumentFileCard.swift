import PalChat
import PalDesign
import SwiftUI

struct DocumentFileCard: View {
    let file: FileReference
    let kind: FileCardKind
    let isStreaming: Bool

    @Environment(\.mediaPreviewResolver) private var mediaResolver
    @Environment(\.chatFileOpener) private var opener
    @State private var loader = MediaPreviewLoader()
    @State private var thumbnail: CGImage?
    @State private var attempt = 0
    @State private var transfer = MediaFilePhase.idle
    @State private var transferTask: Task<Void, Never>?
    #if os(macOS)
    @FocusState private var focused: Bool
    #endif

    private var media: MediaReference { MediaReference(file: file) }
    private var resolver: FileCardResolver? {
        mediaResolver.map { FileCardResolver(media: $0) }
    }
    private var thumbnailKey: String { "document:\(file.id)" }
    private var shown: MediaPreviewState { loader.displayed(cached: resolver?.cached(media, kind: kind)) }

    private var shownThumbnail: CGImage? {
        guard kind.hasThumbnail else { return nil }
        return thumbnail ?? ChatImageDecoder.cached(id: thumbnailKey, maxPixel: DocumentCardMetrics.thumbnailPixels)
    }

    private var strip: DocumentStrip {
        let typeLabel = kind.typeLabel(of: file)
        let base = DocumentStrip(name: file.name, typeLabel: typeLabel, kind: kind)
        switch shown {
        case .ready(let preview): return base.with(preview)
        case .tooLarge(let size): return DocumentStrip(name: file.name, typeLabel: typeLabel, kind: kind, size: size)
        case .idle, .loading, .failed: return base
        }
    }

    var body: some View {
        card
            .task(id: "\(file.id)#\(attempt)#\(isStreaming)") { await load() }
            .onDisappear { transferTask?.cancel() }
    }

    @ViewBuilder
    private var card: some View {
        let view = DocumentCard(
            strip: strip, state: shown, thumbnail: shownThumbnail,
            transfer: transfer, open: openFile, download: { withFile(limit: nil) { MediaFileActions.deliver($0, name: file.name) } },
            retry: { if loader.retry() { attempt += 1 } }
        )
        #if os(macOS)
        view
            .focusable()
            .focused($focused)
            .onKeyPress(.return) { openOnKey() }
            .onKeyPress(.space) { openOnKey() }
            .contextMenu {
                Button("Open", action: openFile)
                Button("Save As…") { withFile { MediaFileActions.deliver($0, name: file.name) } }
                Button("Reveal in Finder") { withFile { MediaFileActions.revealing($0) } }
            }
        #else
        view
        #endif
    }

    private func openFile() {
        opener?(file)
    }

    #if os(macOS)
    private func openOnKey() -> KeyPress.Result {
        guard case .ready = shown else { return .ignored }
        openFile()
        return .handled
    }
    #endif

    private func load() async {
        guard !isStreaming else { return }
        guard let resolver else {
            if loader.start() { loader.finish(.failed(reason: String(localized: "Files aren't available here."), retryable: false)) }
            return
        }
        _ = loader.start()
        guard loader.isLoading else { return }
        do {
            let outcome = try await resolver.resolve(media, kind: kind)
            loader.finish(outcome)
            if case .ready(let preview) = outcome { await decode(preview) }
        } catch {
            loader.cancel()
        }
    }

    private func decode(_ preview: MediaPreview) async {
        guard thumbnail == nil, let data = preview.poster else { return }
        let key = thumbnailKey
        let pixels = DocumentCardMetrics.thumbnailPixels
        thumbnail = await Task.detached(priority: .utility) { ChatImageDecoder.downsample(data, id: key, maxPixel: pixels) }.value
    }

    private func withFile(limit: Int? = MediaLimits.downloadBytes, then action: @escaping @MainActor (URL) -> Void) {
        guard let mediaResolver, transferTask == nil else { return }
        transferTask = MediaFetch.run(media, source: mediaResolver.source, limit: limit, progress: { transfer = .fetching($0) }, completion: { phase in
            transferTask = nil
            if case .ready(let url) = phase {
                transfer = .idle
                action(url)
            } else {
                transfer = phase
            }
        })
    }
}
