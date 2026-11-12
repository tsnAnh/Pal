import AVKit
import Combine
import PalDesign
import SwiftUI

struct VideoBlockView: View {
    let url: URL

    @State private var player: AVPlayer?
    @State private var failed = false
    @Environment(\.hermesTheme) private var theme
    @ScaledMetric(relativeTo: .largeTitle) private var playSize: CGFloat = 44

    private var hostLabel: String {
        url.host(percentEncoded: false) ?? url.lastPathComponent
    }

    var body: some View {
        Group {
            if failed {
                failureState
            } else if let player {
                InlineVideoPlayer(player: player) { failed = true }
            } else {
                poster
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Video from \(hostLabel)")
    }

    private var poster: some View {
        Button {
            player = AVPlayer(url: url)
            player?.play()
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: PalMetrics.cardRadius, style: .continuous)
                    .fill(PalTokens.chipFill)
                VStack(spacing: 6) {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: playSize))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(PalTokens.textPrimary)
                    Text(hostLabel)
                        .hermesText(.chip)
                        .foregroundStyle(PalTokens.textTertiary)
                        .lineLimit(1)
                }
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Play video")
    }

    private var failureState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(url.absoluteString)
                .hermesText(.chatCode)
                .font(RichCode.font)
                .foregroundStyle(PalTokens.textPrimary)
                .textSelection(.enabled)
            Text("This video could not be played.")
                .hermesText(.rowTitle)
                .foregroundStyle(PalTokens.textSecondary)
            Button("Open in browser") {
                ExternalLink.open(url)
            }
            .buttonStyle(.pill())
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(theme.palette.groupedCard), in: RoundedRectangle(cornerRadius: PalMetrics.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: PalMetrics.cardRadius, style: .continuous).stroke(Color(theme.palette.cardStroke), lineWidth: 1))
    }
}

private struct InlineVideoPlayer: View {
    let player: AVPlayer
    let onFailure: () -> Void

    var body: some View {
        VideoPlayer(player: player)
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: PalMetrics.cardRadius, style: .continuous))
            .onReceive(statusFailures) { _ in onFailure() }
            .onReceive(playbackFailures) { _ in onFailure() }
            .onDisappear { player.pause() }
    }

    private var statusFailures: AnyPublisher<Void, Never> {
        guard let item = player.currentItem else { return Empty().eraseToAnyPublisher() }
        return item.publisher(for: \.status)
            .filter { $0 == .failed }
            .map { _ in () }
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }

    private var playbackFailures: AnyPublisher<Notification, Never> {
        NotificationCenter.default
            .publisher(for: AVPlayerItem.failedToPlayToEndTimeNotification, object: player.currentItem)
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }
}
