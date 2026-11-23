import PalChat
import PalDesign
import SwiftUI

struct AudioBar: View {
    let media: MediaReference

    @Environment(\.mediaPreviewResolver) private var resolver
    @State private var loader = MediaPreviewLoader()
    @State private var attempt = 0
    @State private var file = MediaFilePhase.idle
    @State private var fetchTask: Task<Void, Never>?
    @State private var transfer = MediaFilePhase.idle
    @State private var transferTask: Task<Void, Never>?
    @State private var playback = AudioPlayback()
    @State private var scrubbing = false
    @State private var scrubValue = 0.0

    private static let width = MediaTileMetrics.single

    private var shown: MediaPreviewState { loader.displayed(cached: resolver?.cached(media)) }

    var body: some View {
        content
            .task(id: "\(media.id)#\(attempt)") { await load() }
            .onDisappear {
                playback.stop()
                fetchTask?.cancel()
                transferTask?.cancel()
                if case .ready(let url) = file { MediaDownloads.remove(url) }
                file = .idle
            }
    }

    @ViewBuilder
    private var content: some View {
        switch shown {
        case .idle, .loading, .ready:
            bar(duration: knownDuration)
        case .tooLarge(let size):
            MediaTooLargeCard(media: media, size: size, compact: false, transfer: transfer) { download() }
                .frame(width: Self.width, height: 128)
        case .failed(let reason, let retryable):
            MediaFailedCard(reason: reason, retryable: retryable, kind: .audio) {
                if loader.retry() { attempt += 1 }
            }
            .frame(width: Self.width, height: 64)
        }
    }

    private var knownDuration: TimeInterval {
        if playback.duration > 0 { return playback.duration }
        if case .ready(let preview) = shown { return preview.duration ?? media.duration ?? 0 }
        return media.duration ?? 0
    }

    private func bar(duration: TimeInterval) -> some View {
        HStack(spacing: 8) {
            Button(action: toggle) { playGlyph }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(playback.isPlaying ? "Pause \(media.name)" : "Play \(media.name)"))
                .accessibilityIdentifier("chatAudioPlay")
            VStack(alignment: .leading, spacing: 2) {
                Text(media.name)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(PalTokens.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                scrubber(duration: duration)
                caption(duration: duration)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: Self.width, alignment: .leading)
        .mediaCardFill()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chatAudioBar")
    }

    @ViewBuilder
    private var playGlyph: some View {
        Group {
            if case .fetching(let fraction) = file {
                ProgressView(value: fraction)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .tint(PalTokens.textPrimary)
            } else {
                PalIcon(playback.isPlaying ? "pause.fill" : "play.fill", ink: .primary)
                    .font(.system(size: 16))
            }
        }
        .frame(width: 32, height: 32)
        .contentShape(Circle())
    }

    private func scrubber(duration: TimeInterval) -> some View {
        Slider(
            value: Binding(get: { scrubbing ? scrubValue : playback.position }, set: { scrubValue = $0 }),
            in: 0...max(duration, 1)
        ) { editing in
            if !editing { playback.seek(to: scrubValue) }
            scrubbing = editing
        }
        .controlSize(.mini)
        .tint(PalTokens.textPrimary)
        .disabled(duration <= 0 || playback.duration <= 0)
        .accessibilityLabel(Text("Playback position"))
        .accessibilityIdentifier("chatAudioScrubber")
    }

    @ViewBuilder
    private func caption(duration: TimeInterval) -> some View {
        if case .failed(let message, _) = file {
            Text(message)
                .hermesText(.timestamp)
                .foregroundStyle(PalTokens.textSecondary)
                .lineLimit(2)
        } else {
            Text("\(MediaDuration.label(playback.position)) / \(MediaDuration.label(duration))")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(PalTokens.textSecondary)
        }
    }

    private func load() async {
        guard let resolver else {
            if loader.start() { loader.finish(.failed(reason: String(localized: "Media isn't available here."), retryable: false)) }
            return
        }
        _ = loader.start()
        guard loader.isLoading else { return }
        do {
            loader.finish(try await resolver.resolve(media))
        } catch {
            loader.cancel()
        }
    }

    private func toggle() {
        if playback.isPlaying {
            playback.pause()
        } else if case .ready(let url) = file {
            playback.play(url, id: media.id)
        } else {
            fetch()
        }
    }

    private func fetch() {
        guard let resolver, fetchTask == nil else { return }
        file = .fetching(nil)
        fetchTask = MediaFetch.run(media, source: resolver.source, limit: MediaLimits.downloadBytes, progress: { file = .fetching($0) }, completion: { phase in
            fetchTask = nil
            file = phase
            if case .ready(let url) = phase { playback.play(url, id: media.id) }
        })
    }

    private func download() {
        guard let resolver, transferTask == nil else { return }
        transferTask = MediaFetch.run(media, source: resolver.source, limit: nil, progress: { transfer = .fetching($0) }, completion: { phase in
            transferTask = nil
            if case .ready(let url) = phase {
                transfer = .idle
                MediaFileActions.deliver(url, name: media.name)
            } else {
                transfer = phase
            }
        })
    }
}
