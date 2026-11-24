import PalChat
import PalDiagnostics
import SwiftUI

extension ChatScrollController {
    func renderPlan(of rows: [ChatRow], persisted: ChatRowHeightFile?, textScale: String) -> ChatTailPlan {
        _ = planTick
        tracker.textScale = textScale
        let geometry = lastGeometry
        return planner.resolve(
            rows: rows,
            context: .init(persisted: persisted, viewport: geometry.map(\.containerHeight), width: geometry.map(\.containerWidth)),
            measured: { [rowHeights] id, width in rowHeights.height(of: id, width: width) },
            seed: { [rowHeights] row, height, width in rowHeights.adopt(row.id, height: height, width: width, layout: row.layoutKey) }
        )
    }

    func persistHeights() {
        guard let (store, bot) = heights, let geometry = lastGeometry, geometry.containerWidth > 0 else { return }
        let width = geometry.containerWidth
        let file = planner.file(width: width, textScale: tracker.textScale, viewport: geometry.containerHeight) { [rowHeights] in
            rowHeights.height(of: $0, width: width)
        }
        store.save(file, for: bot)
    }

    func observeTail(_ snapshot: ChatScrollGeometry, previous: ChatScrollGeometry?) -> Bool {
        if let previous, abs(previous.containerWidth - snapshot.containerWidth) > Self.restoreTolerance { planner.widthChanged() }
        tracker.meter.geometry(snapshot, atMilliseconds: tracker.elapsedMilliseconds)
        touch()
        if planner.hiddenHeight > 0, snapshot.distanceFromTop - planner.hiddenHeight < snapshot.containerHeight * Self.tailLeadViewports {
            scheduleTailExtension()
        }
        return snapshot.wantsOlder && planner.hiddenHeight == 0
    }

    func noteLaidOut(_ id: String, height: Double, width: Double) {
        touch()
        rowHeights.laidOut(id, height: height, width: width)
        planner.observe(id, height: height, width: width)
    }

    func noteRendered(_ ids: [String]) -> [String] {
        tracker.meter.rows(count: ids.count)
        return ids
    }

    func tailMoved() {
        planTick &+= 1
        send(.rowsChanged(noteRendered(planner.renderedIDs)))
    }

    private func touch() {
        tracker.lastEventAt = .now
        guard tracker.quietTask == nil else { return }
        tracker.quietTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: ChatTailPlanner.quiet)
                guard let self, !Task.isCancelled else { return }
                guard tracker.lastEventAt.duration(to: .now) >= ChatTailPlanner.quiet else { continue }
                tracker.quietTask = nil
                settled()
                return
            }
        }
    }

    private func settled() {
        persistHeights()
        guard !tracker.reported, let (_, bot) = heights else { return }
        tracker.reported = true
        let report = tracker.meter.report(atMilliseconds: tracker.elapsedMilliseconds)
        LaunchClock.mark(
            "chat \(bot) layout first \(Int(report.firstContent)) settled \(Int(report.settledContent)) in \(report.settleMilliseconds) ms, "
                + "past end \(Int(report.maxPastEnd)), rows hit zero \(report.rowsHitZero)",
            on: .osLog()
        )
    }

    private func scheduleTailExtension() {
        guard !tracker.tailExtensionScheduled else { return }
        tracker.tailExtensionScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            tracker.tailExtensionScheduled = false
            guard let geometry = lastGeometry else { return }
            let deficit = geometry.containerHeight * Self.tailLeadViewports - (geometry.distanceFromTop - planner.hiddenHeight)
            if planner.extend(deficit: max(deficit, 0)) { tailMoved() }
        }
    }
}
