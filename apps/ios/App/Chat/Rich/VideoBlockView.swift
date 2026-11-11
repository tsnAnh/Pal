import AVKit
import Combine
import SwiftUI

struct VideoBlockView: View {
    let url: URL

    @State private var player: AVPlayer?
    @State private var failed = false

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
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.secondary.opacity(0.14))
                VStack(spacing: 6) {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 44))
                        .symbolRenderingMode(.hierarchical)
                    Text(hostLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
            Text("This video could not be played.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Open in browser") {
                ExternalLink.open(url)
            }
            .buttonStyle(.bordered)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct InlineVideoPlayer: View {
    let player: AVPlayer
    let onFailure: () -> Void

    var body: some View {
        VideoPlayer(player: player)
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
