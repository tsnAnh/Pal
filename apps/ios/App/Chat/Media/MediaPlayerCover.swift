#if os(iOS)
import AVFoundation
import AVKit
import PalChat
import PalDesign
import SwiftUI

struct MediaPlayerCover: View {
    @Binding var state: MediaViewerState
    let source: any MediaAssetSource
    let close: () -> Void

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        NavigationStack {
            MediaPlaybackStage(state: $state, source: source) { url in
                SystemVideoPlayer(url: url)
                    .ignoresSafeArea(edges: .bottom)
            }
            .background(Color(theme.palette.canvas))
            .navigationTitle(state.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    PalCloseButton(action: close)
                        .accessibilityIdentifier("mediaViewerClose")
                }
            }
            .toolbarTitleDisplayMode(.inline)
        }
        .accessibilityIdentifier("mediaViewer")
    }
}

private struct SystemVideoPlayer: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        let controller = AVPlayerViewController()
        controller.player = AVPlayer(url: url)
        controller.allowsPictureInPicturePlayback = true
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        let current = (controller.player?.currentItem?.asset as? AVURLAsset)?.url
        if current != url { controller.player = AVPlayer(url: url) }
    }

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: ()) {
        controller.player?.pause()
        controller.player = nil
    }
}
#endif
