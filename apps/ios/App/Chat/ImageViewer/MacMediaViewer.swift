#if os(macOS)
import AVKit
import PalChat
import PalDesign
import SwiftUI

struct MacMediaViewerHost: View {
    @Binding var viewer: MediaViewerState?
    let source: any MediaAssetSource

    var body: some View {
        if let state = Binding($viewer) {
            MacMediaViewer(state: state, source: source, close: close)
        }
    }

    private func close() {
        for file in MediaViewerState.close(&viewer) { MediaDownloads.remove(file) }
    }
}

private struct MacMediaViewer: View {
    @Binding var state: MediaViewerState
    let source: any MediaAssetSource
    let close: () -> Void

    @State private var player = AVPlayer()
    @State private var staging = MediaDragStaging()
    @FocusState private var focused: Bool

    private var file: URL? { state.file(for: state.current.id) }

    var body: some View {
        ViewerShell(
            title: state.title,
            actions: [.download, .close],
            disabled: file == nil ? [.download] : [],
            perform: perform,
            drag: dragProvider
        ) {
            MediaPlaybackStage(state: $state, source: source) { url in
                MacPlayerView(player: player, url: url)
            }
            .accessibilityIdentifier("mediaViewer")
        } composer: {
            EmptyView()
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(.leftArrow) { step(-1) }
        .onKeyPress(.rightArrow) { step(1) }
        .onKeyPress(.space) { togglePlayback() }
        .onKeyPress(.escape) {
            close()
            return .handled
        }
        .onCopyCommand { file.map(MediaDrag.copyable) ?? [] }
        .onDisappear {
            player.pause()
            staging.release()
        }
    }

    private func dragProvider() -> NSItemProvider {
        MediaDrag.provider(for: state.current.reference, source: source, staging: staging, ready: file)
    }

    private func perform(_ action: ViewerAction) {
        switch action {
        case .download:
            if let file { MediaFileActions.saveAs(file, suggestedName: state.current.reference.name) }
        case .close:
            close()
        case .edit, .openInBrowser:
            break
        }
    }

    private func step(_ delta: Int) -> KeyPress.Result {
        player.pause()
        if delta < 0 { state.goPrevious() } else { state.goNext() }
        return .handled
    }

    private func togglePlayback() -> KeyPress.Result {
        if player.timeControlStatus == .paused { player.play() } else { player.pause() }
        return .handled
    }
}

private final class KeyboardTransparentPlayerView: AVPlayerView {
    override var acceptsFirstResponder: Bool { false }
}

private struct MacPlayerView: NSViewRepresentable {
    let player: AVPlayer
    let url: URL

    final class Coordinator {
        var url: URL?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = KeyboardTransparentPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = true
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        guard context.coordinator.url != url else { return }
        context.coordinator.url = url
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: Coordinator) {
        view.player?.pause()
    }
}
#endif
