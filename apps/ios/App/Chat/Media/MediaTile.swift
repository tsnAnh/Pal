import PalChat
import PalDesign
import SwiftUI

struct MediaTile: View {
    let media: MediaReference
    let width: CGFloat
    let height: CGFloat

    @Environment(\.mediaPreviewResolver) private var resolver
    @Environment(\.mediaOpener) private var opener
    @Environment(\.mediaRowID) private var rowID
    @State private var loader = MediaPreviewLoader()
    @State private var poster: CGImage?
    @State private var attempt = 0
    @State private var transfer = MediaFilePhase.idle
    @State private var transferTask: Task<Void, Never>?
    @State private var hovering = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: PalMetrics.cardRadius, style: .continuous)
    }

    private var compact: Bool { width < 150 }
    private var posterKey: String { "poster:\(media.id)" }
    private var posterPixels: Int { Int(width * 3) }

    private var shown: MediaPreviewState { loader.displayed(cached: resolver?.cached(media)) }

    var body: some View {
        content
            .frame(width: width, height: height)
            .clipShape(shape)
            .shadow(color: PalTokens.scrim.opacity(0.22), radius: 6, y: 2)
            .contentShape(shape)
            .task(id: "\(media.id)#\(attempt)") { await load() }
            .onDisappear { transferTask?.cancel() }
    }

    @ViewBuilder
    private var content: some View {
        switch shown {
        case .idle, .loading:
            ZStack {
                PalTokens.agentBubble
                DelayedProgressView(after: ChatLoading.delay).controlSize(.small).tint(PalTokens.textTertiary)
            }
            .accessibilityIdentifier("chatMediaLoading")
        case .ready(let preview):
            readyTile(preview)
        case .tooLarge(let size):
            MediaTooLargeCard(media: media, size: size, compact: compact, transfer: transfer) { download() }
        case .failed(let reason, let retryable):
            MediaFailedCard(reason: reason, retryable: retryable, kind: media.kind) {
                if loader.retry() { attempt += 1 }
            }
        }
    }

    private func readyTile(_ preview: MediaPreview) -> some View {
        Button { opener?(media, rowID) } label: {
            ZStack {
                posterLayer
                playGlyph
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    footer(preview)
                }
                transferBadge
            }
            .frame(width: width, height: height)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(Text("Video \(media.name). Tap to play"))
        .accessibilityIdentifier("chatMediaTile")
        .modifier(
            MediaTileMenu(
                open: { opener?(media, rowID) },
                save: { withFile { MediaFileActions.deliver($0, name: media.name) } },
                reveal: { withFile { MediaFileActions.revealing($0) } }
            )
        )
    }

    @ViewBuilder
    private var posterLayer: some View {
        if let image = poster ?? ChatImageDecoder.cached(id: posterKey, maxPixel: posterPixels) {
            Image(platformImage: PlatformImage(cgImage: image))
                .resizable()
                .scaledToFill()
                .frame(width: width, height: height)
                .clipped()
        } else {
            ZStack {
                PalTokens.agentBubble
                PalIcon("film", ink: .tertiary).font(.system(size: compact ? 17 : 24))
            }
        }
    }

    private var playGlyph: some View {
        PalIcon("play.fill", ink: .primary)
            .font(.system(size: compact ? 14 : 20))
            .frame(width: compact ? 36 : 52, height: compact ? 36 : 52)
            .palClearGlass(Circle(), interactive: false)
            .opacity(hovering ? 1 : 0.85)
    }

    private func footer(_ preview: MediaPreview) -> some View {
        PalGlassContainer(spacing: 6) {
            HStack(alignment: .bottom, spacing: 6) {
                Text(media.name)
                    .font(.caption2)
                    .foregroundStyle(PalTokens.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .palClearGlass(Capsule(), interactive: false)
                Spacer(minLength: 0)
                if let duration = preview.duration ?? media.duration {
                    Text(MediaDuration.label(duration))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(PalTokens.textPrimary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .palClearGlass(Capsule(), interactive: false)
                        .fixedSize()
                        .accessibilityIdentifier("chatMediaDuration")
                }
            }
            .padding(6)
        }
    }

    @ViewBuilder
    private var transferBadge: some View {
        switch transfer {
        case .fetching(let fraction):
            badge { ProgressView(value: fraction).controlSize(.small).tint(PalTokens.textPrimary) }
        case .failed(let message, _):
            badge {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(PalTokens.textPrimary)
                    .lineLimit(2)
                    .accessibilityIdentifier("chatMediaTransferFailed")
            }
        case .idle, .ready:
            EmptyView()
        }
    }

    private func badge<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(8)
            .palClearGlass(Capsule(), interactive: false)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(6)
    }

    private func load() async {
        guard let resolver else {
            if loader.start() { loader.finish(.failed(reason: String(localized: "Media isn't available here."), retryable: false)) }
            return
        }
        _ = loader.start()
        guard loader.isLoading else { return }
        do {
            let outcome = try await resolver.resolve(media)
            loader.finish(outcome)
            if case .ready(let preview) = outcome { await decodePoster(preview) }
        } catch {
            loader.cancel()
        }
    }

    private func decodePoster(_ preview: MediaPreview) async {
        guard poster == nil, let data = preview.poster else { return }
        let key = posterKey
        let pixels = posterPixels
        poster = await Task.detached(priority: .utility) { ChatImageDecoder.downsample(data, id: key, maxPixel: pixels) }.value
    }

    private func download() {
        withFile(limit: nil) { MediaFileActions.deliver($0, name: media.name) }
    }

    private func withFile(limit: Int? = MediaLimits.downloadBytes, then action: @escaping @MainActor (URL) -> Void) {
        guard let resolver, transferTask == nil else { return }
        transferTask = MediaFetch.run(media, source: resolver.source, limit: limit, progress: { transfer = .fetching($0) }, completion: { phase in
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

private struct MediaTileMenu: ViewModifier {
    let open: () -> Void
    let save: () -> Void
    let reveal: () -> Void

    func body(content: Content) -> some View {
        #if os(macOS)
        content.contextMenu {
            Button("Open", action: open)
            Button("Save As…", action: save)
            Button("Reveal in Finder", action: reveal)
        }
        #else
        content
        #endif
    }
}
