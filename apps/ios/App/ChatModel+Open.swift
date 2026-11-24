import Foundation
import PalChat
import PalDiagnostics

extension ChatModel {
    func acceptsSnapshot(_ next: TimelineSnapshot) -> Bool {
        guard let snapshot, !snapshotFromEarlierRun else { return true }
        return next.version > snapshot.version
    }

    func takePreviousSnapshot() -> TimelineSnapshot? {
        defer { snapshotFromEarlierRun = false }
        return snapshotFromEarlierRun ? nil : snapshot
    }

    func closeOpening() {
        openingDeadline?.cancel()
        openingDeadline = nil
        snapshotFromEarlierRun = snapshot != nil
    }

    static let openingTimeout = Duration.seconds(3)

    func armOpeningDeadline(after timeout: Duration = ChatModel.openingTimeout) {
        openingDeadline?.cancel()
        openingDeadline = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self, isOpening else { return }
            traceStalled("opening lasted past \(timeout.components.seconds) s")
            endOpening("timed-out")
        }
    }

    func endOpening(_ reason: String) {
        isOpening = false
        openingDeadline?.cancel()
        openingDeadline = nil
        opening.firstPaint()
        traceOpen("opening.\(reason)")
    }

    func traceOpen(_ stage: String) {
        if !rows.isEmpty, windowRange.isEmpty { traceStalled("rows exist but none are rendered") }
        guard ChatOpenTrace.isOn else { return }
        ChatOpenTrace.mark(
            openedBot.name, stage, rows: rows.count,
            detail: "rendered=\(windowRange.count) window=\(windowRange.lowerBound)..<\(windowRange.upperBound) "
                + "opening=\(isOpening) session=\(snapshot?.sessionID != nil) snapshotRows=\(snapshot?.rows.count ?? -1)"
        )
    }

    private func traceStalled(_ reason: String) {
        let detail = "rows=\(rows.count) rendered=\(windowRange.count) opening=\(isOpening) session=\(snapshot?.sessionID != nil)"
        ChatOpenTrace.mark(openedBot.name, "open.stalled", rows: rows.count, detail: reason)
        LaunchClock.mark("chat \(openedBot.name) open stalled: \(reason) (\(detail))", on: .osLog())
    }
}
