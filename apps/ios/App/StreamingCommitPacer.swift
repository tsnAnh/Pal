import Foundation
import PalChat

@MainActor
final class StreamingCommitPacer {
    private var gate: StreamCommitGate
    private var pending: StreamingRowPatch?
    private var flush: Task<Void, Never>?
    private let clock = ContinuousClock()

    init(interval: Duration = StreamCommitGate.defaultInterval) {
        gate = StreamCommitGate(interval: interval)
    }

    var interval: Duration {
        get { gate.interval }
        set { gate.interval = newValue }
    }

    func submit(_ patch: StreamingRowPatch, apply: @escaping @MainActor (StreamingRowPatch) -> Void) {
        switch gate.offer(at: clock.now, final: !patch.row.isStreaming) {
        case .commitNow:
            drop()
            apply(patch)
        case .wait(let delay):
            pending = patch
            guard flush == nil else { return }
            flush = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self, let latest = pending else { return }
                flush = nil
                pending = nil
                gate.committed(at: clock.now)
                apply(latest)
            }
        }
    }

    func reset() {
        drop()
        gate.reset()
    }

    private func drop() {
        flush?.cancel()
        flush = nil
        pending = nil
    }
}
