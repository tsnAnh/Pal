import Foundation
import PalChat
import PalDiagnostics

@MainActor
final class ChatOpenCoordinator {
    static let settleWindow = Duration.milliseconds(300)

    private var gate = ChatOpenGate()
    private var holdTimer: Task<Void, Never>?
    private var settleTimer: Task<Void, Never>?
    private var liveSeen = true
    private(set) var isWindowOpen = false
    private var attempts = 0

    func hold(version: UInt64, release: @escaping @MainActor (TimelineSnapshot) -> Void) {
        gate.hold(version: version)
        liveSeen = false
        holdTimer = Task { [weak self] in
            try? await Task.sleep(for: ChatOpenGate.bound)
            guard !Task.isCancelled, let held = self?.gate.release() else { return }
            release(held)
        }
    }

    func admit(_ next: TimelineSnapshot) -> TimelineSnapshot? {
        guard let ready = gate.admit(next) else { return nil }
        if !gate.isHolding {
            holdTimer?.cancel()
            liveSeen = true
        }
        return ready
    }

    func firstPaint() {
        isWindowOpen = true
        PalPerf.event("chat.open.firstpaint")
    }

    func rowsChanged() {
        guard isWindowOpen, liveSeen else { return }
        settleTimer?.cancel()
        settleTimer = Task { [weak self] in
            try? await Task.sleep(for: Self.settleWindow)
            guard !Task.isCancelled, let self else { return }
            isWindowOpen = false
            PalPerf.event("chat.open.settled")
        }
    }

    func retrying(after delay: Duration) {
        attempts += 1
        PalPerf.event("chat.open.retry", count: attempts)
        PalPerf.event("chat.open.retry.delay", count: Int(delay.components.seconds * 1000 + delay.components.attoseconds / 1_000_000_000_000_000))
    }

    func reset() {
        cancel()
        gate = ChatOpenGate()
        liveSeen = true
        isWindowOpen = false
        attempts = 0
    }

    func cancel() {
        holdTimer?.cancel()
        settleTimer?.cancel()
    }
}
