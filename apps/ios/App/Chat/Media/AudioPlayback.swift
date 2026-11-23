import AVFoundation
import Observation
import PalChat

@MainActor
final class AudioPlaybackCoordinator {
    static let shared = AudioPlaybackCoordinator()

    private var activeID: String?
    private var stopActive: (() -> Void)?

    func claim(_ id: String, stop: @escaping () -> Void) {
        if activeID != id { stopActive?() }
        activeID = id
        stopActive = stop
    }

    func release(_ id: String) {
        guard activeID == id else { return }
        activeID = nil
        stopActive = nil
    }
}

@MainActor
@Observable
final class AudioPlayback {
    private(set) var isPlaying = false
    private(set) var position: TimeInterval = 0
    private(set) var duration: TimeInterval = 0

    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var observer: Any?
    @ObservationIgnored private var finished: NSObjectProtocol?
    @ObservationIgnored private var id = ""

    func play(_ file: URL, id: String) {
        self.id = id
        if player == nil { prepare(file) }
        AudioPlaybackCoordinator.shared.claim(id) { [weak self] in self?.stop() }
        Self.activateSession()
        player?.play()
        isPlaying = true
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func seek(to seconds: TimeInterval) {
        position = seconds
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func stop() {
        pause()
        teardown()
        AudioPlaybackCoordinator.shared.release(id)
    }

    private func prepare(_ file: URL) {
        let item = AVPlayerItem(url: file)
        let player = AVPlayer(playerItem: item)
        self.player = player
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time) }
        }
        finished = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didFinish() }
        }
        Task { [weak self] in
            let loaded = try? await item.asset.load(.duration).seconds
            if let loaded, loaded.isFinite { self?.duration = loaded }
        }
    }

    private func tick(_ time: CMTime) {
        let seconds = time.seconds
        if seconds.isFinite { position = seconds }
    }

    private func didFinish() {
        isPlaying = false
        position = 0
        player?.seek(to: .zero)
    }

    private func teardown() {
        if let observer { player?.removeTimeObserver(observer) }
        if let finished { NotificationCenter.default.removeObserver(finished) }
        observer = nil
        finished = nil
        player = nil
        position = 0
    }

    private static func activateSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
        #endif
    }
}
