import PalChat
import PalDesign
import SwiftUI

struct MediaPlaybackStage<Player: View>: View {
    @Binding var state: MediaViewerState
    let source: any MediaAssetSource
    @ViewBuilder let player: (URL) -> Player

    @State private var phase = MediaFilePhase.idle
    @State private var attempt = 0

    var body: some View {
        Group {
            switch phase {
            case .idle, .fetching:
                preparing
            case .ready(let url):
                player(url)
                    .accessibilityIdentifier("mediaViewerPlayer")
            case .failed(let message, let retryable):
                failure(message, retryable: retryable)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity) // chat-row-alignment: ok full-screen viewer, not a chat row
        .task(id: "\(state.current.id)#\(attempt)") { await prepare() }
    }

    private var preparing: some View {
        VStack(spacing: 10) {
            if case .fetching(let fraction) = phase {
                ProgressView(value: fraction).frame(maxWidth: 220)
                if let fraction {
                    Text("\(Int(fraction * 100))%")
                        .hermesText(.timestamp)
                        .foregroundStyle(PalTokens.textSecondary)
                }
            } else {
                DelayedProgressView()
            }
        }
        .accessibilityIdentifier("mediaViewerLoading")
    }

    private func failure(_ message: String, retryable: Bool) -> some View {
        VStack(spacing: 10) {
            PalIcon("film", ink: .secondary).font(.system(size: 32))
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(PalTokens.textSecondary)
            if retryable {
                Button { attempt += 1 } label: { Label("Retry", palIcon: "arrow.clockwise") }
                    .glassButtonStyle()
                    .accessibilityIdentifier("mediaViewerRetry")
            }
        }
        .padding()
        .accessibilityIdentifier("mediaViewerFailed")
    }

    private func prepare() async {
        let item = state.current
        if let kept = state.file(for: item.id), FileManager.default.fileExists(atPath: kept.path) {
            phase = .ready(kept)
            return
        }
        phase = .fetching(nil)
        let result = await MediaFetch.file(item.reference, from: source, limit: MediaLimits.downloadBytes) { fraction in
            if case .fetching = phase { phase = .fetching(fraction) }
        }
        guard !Task.isCancelled else {
            if case .ready(let url) = result { MediaDownloads.remove(url) }
            return
        }
        if case .ready(let url) = result { state.record(url, for: item.id) }
        phase = result
    }
}
