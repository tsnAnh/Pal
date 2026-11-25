import PalChat
import PalDiagnostics
import SwiftUI

extension ChatScrollController {
    var isResizing: Bool { resizeSettleTask != nil }

    func widthMoved() {
        let started = resizeSettleTask == nil
        if started { send(.layoutMoving(true)) }
        resizeSettleTask?.cancel()
        resizeSettleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.resizeSettle)
            guard let self, !Task.isCancelled else { return }
            resizeSettleTask = nil
            send(.layoutMoving(false))
            releaseEdgeOnceAtBottom()
            planner.endResizing()
            rowHeights.widthChanged()
            measureTick &+= 1
            planTick &+= 1
        }
        if started { planTick &+= 1 }
    }

    func renderPlan(of rows: [ChatRow], persisted: ChatRowHeightFile?, textScale: String) -> ChatTailPlan {
        _ = planTick
        tracker.textScale = textScale
        let geometry = lastGeometry
        let settled = planner.resolve(
            rows: rows,
            context: .init(persisted: persisted, viewport: geometry.map(\.containerHeight), width: geometry.map(\.containerWidth)),
            measured: { [rowHeights] id, width in rowHeights.height(of: id, width: width) },
            seed: { [rowHeights] row, height, width in rowHeights.adopt(row.id, height: height, width: width, layout: row.layoutKey) }
        )
        guard isResizing, isPinnedToBottom else { return settled }
        return planner.resizingPlan(viewport: geometry.map(\.containerHeight))
    }

    func holdNewestRow(_ id: String, frame: CGRect) {
        let rows = planner.currentRows
        guard id == rows.last?.id else { return }
        let next = ChatNewestAnchor(id: id, firstID: rows.first?.id, width: Double(frame.width), minY: Double(frame.minY))
        guard let anchor = newestAnchor, anchor.isSameLayout(as: next), ContinuousClock.now < holdsUntil, isPinnedToBottom,
              !machine.isUserScrolling, !isResizing, planner.holdDocument(shiftedBy: next.minY - anchor.minY)
        else {
            newestAnchor = next
            return
        }
        planTick &+= 1
    }

    func persistHeights() {
        guard let (store, bot) = heights, let geometry = lastGeometry, geometry.containerWidth > 0 else { return }
        let width = geometry.containerWidth
        let file = planner.file(width: width, textScale: tracker.textScale, viewport: geometry.containerHeight) { [rowHeights] in
            rowHeights.height(of: $0, width: width)
        }
        store.save(file, for: bot)
    }

    func observeTail(_ snapshot: ChatScrollGeometry) -> Bool {
        tracker.meter.geometry(snapshot, atMilliseconds: tracker.elapsedMilliseconds)
        touch()
        if !isResizing, planner.hiddenHeight > 0, snapshot.distanceFromTop - planner.hiddenHeight < snapshot.containerHeight * Self.tailLeadViewports {
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

    func armDocumentHold() {
        holdsUntil = .now + Self.holdWindow
    }

    func tailMoved() {
        armDocumentHold()
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

struct ChatNewestAnchor {
    let id: String
    let firstID: String?
    let width: Double
    let minY: Double

    func isSameLayout(as other: ChatNewestAnchor) -> Bool {
        id == other.id && firstID == other.firstID && abs(width - other.width) <= ChatTailPlanner.anchorTolerance
    }
}
