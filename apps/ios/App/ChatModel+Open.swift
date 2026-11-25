import Foundation
import PalChat
import PalDiagnostics

extension ChatModel {
    var snapshotFromEarlierRun: Bool {
        get { openStats.snapshotFromEarlierRun }
        set { openStats.snapshotFromEarlierRun = newValue }
    }

    func acceptsSnapshot(_ next: TimelineSnapshot) -> Bool {
        if next.rows.isEmpty, !rows.isEmpty, !next.provesEmptyConversation { return false }
        guard let snapshot, !snapshotFromEarlierRun else { return true }
        return next.version > snapshot.version
    }

    func beginOpen() {
        isActive = true
        openCount += 1
        guard openCount > 1 else { return }
        opening.reset()
        openStats = ChatOpenStats()
        openStats.heights = links.heights.remembered(for: openedBot.name)
        snapshotFromEarlierRun = snapshot != nil
        isOpening = rows.isEmpty
        hasBeenLive = false
        assignIfChanged(\.connection, .connecting)
        lastSeenAtOpen = lastSeenStore.lastSeen(for: bot.name)
        endFinding()
        cancelReply()
        sendError = nil
        imageViewer = nil
        documentViewer = nil
        filePreview = nil
        localImages = [:]
    }

    var persistedHeights: ChatRowHeightFile? { openStats.heights }

    func restoreSession(_ session: ChatSession) async {
        async let heights = links.heights.load(for: openedBot.name)
        await session.restore()
        openStats.heights = await heights
    }

    func seedFromMemory() {
        openStats.heights = links.heights.remembered(for: openedBot.name)
        guard let remembered = links.snapshots.snapshot(for: openedBot.name) else { return }
        apply(remembered)
        snapshotFromEarlierRun = true
    }

    func showCacheFrame(_ cached: TimelineSnapshot) {
        LaunchClock.mark("chat \(openedBot.name) shown from cache (\(cached.rows.count) rows)", on: .osLog())
        ChatOpenTrace.mark(openedBot.name, "cache.frame", rows: cached.rows.count, detail: "held=false")
        PalPerf.event("chat.open.cache.rows", count: cached.rows.count)
        apply(cached)
        opening.hold(version: cached.version) { [weak self] in self?.apply($0) }
    }

    func noteRows(_ count: Int) {
        let elapsed = Int(openStats.openedAt.duration(to: .now) / .milliseconds(1))
        if count > 0, !openStats.hasShownRows {
            openStats.hasShownRows = true
            PalPerf.event("chat.open.firstrows", label: openedBot.name, since: openStats.openedAt)
            LaunchClock.mark("chat \(openedBot.name) first rows (\(count)) after \(elapsed) ms", on: .osLog())
        } else if count == 0, !rows.isEmpty {
            openStats.clearedAfterData = true
            PalPerf.event("chat.open.rows.cleared")
            LaunchClock.mark("chat \(openedBot.name) rows cleared after data after \(elapsed) ms", on: .osLog())
        }
    }

    func takePreviousSnapshot() -> TimelineSnapshot? {
        defer { snapshotFromEarlierRun = false }
        return snapshotFromEarlierRun ? nil : snapshot
    }

    func closeOpening() {
        if let snapshot { links.snapshots.remember(snapshot, for: openedBot.name) }
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

private extension TimelineSnapshot {
    var provesEmptyConversation: Bool { sessionID != nil && older == .start }
}
