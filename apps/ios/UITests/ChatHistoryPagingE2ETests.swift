import XCTest

private struct LandingMeasurement {
    let gesture: Int
    let style: String
    let oldestBefore: String
    let landedAt: TimeInterval
    let driftAtLanding: CGFloat
    let driftAfter100ms: CGFloat?
    let driftAfter1s: CGFloat?
    let maxDrift: CGFloat

    var json: [String: Any] {
        var values: [String: Any] = [
            "gesture": gesture, "style": style, "oldest_before": oldestBefore,
            "landed_at_s": PagingMeasurements.seconds(landedAt),
            "drift_at_landing_pt": PagingMeasurements.points(driftAtLanding),
            "max_drift_pt": PagingMeasurements.points(maxDrift),
        ]
        if let driftAfter100ms { values["drift_after_100ms_pt"] = PagingMeasurements.points(driftAfter100ms) }
        if let driftAfter1s { values["drift_after_1s_pt"] = PagingMeasurements.points(driftAfter1s) }
        return values
    }
}

@MainActor
final class ChatHistoryPagingE2ETests: BotProfileTestCase {
    private static let driftTolerance: CGFloat = 1
    private static let requiredLandings = 10
    private static let requiredFlings = 3
    private static let landingWindow: TimeInterval = 3
    private static let pagingBudget: TimeInterval = 720
    private static let maxGestures = 400
    private static let scrollToTopBudget: TimeInterval = 480
    private static let scrollToTopMaxGestures = 400
    private static let stallGestures = 15
    private static let pillSettleSeconds: TimeInterval = 12
    private static let openSampleSeconds: TimeInterval = 5
    private static let reconnectOutageSeconds: TimeInterval = 8
    private static let reconnectObservedSeconds: TimeInterval = 20

    private var manifest: PagingManifest!

    override func setUp() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["HERMES_UITEST_SEED"] == "perf", "needs a gateway started with --seed perf and HERMES_UITEST_SEED=perf")
        let manifestPath = environment["HERMES_UITEST_PERF_MANIFEST"] ?? ""
        try XCTSkipIf(manifestPath.isEmpty, "needs HERMES_UITEST_PERF_MANIFEST from the perf seed")
        try await super.setUp()
        manifest = try PagingManifest.load(path: manifestPath)
    }

    private func record(_ values: [String: Any], test: String = #function) {
        let name = test.replacingOccurrences(of: "()", with: "")
        PagingMeasurements.merge(values, test: name, directory: env.shotsDirectory)
        guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys]) else { return }
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "\(name)-measurements"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func openLongChat(_ slug: String) throws -> (app: XCUIApplication, driver: PagingDriver, reading: ChatReading) {
        let app = signedInApp()
        openBot(app, slug)
        let driver = PagingDriver(app: app)
        let reading = try driver.waitForContent(timeout: 60)
        return (app, driver, reading)
    }

    private func landing(in samples: [AnchorSample], anchor: PagingAnchor, oldestBefore: String, gesture: Int, style: String) -> LandingMeasurement? {
        let oldestOrdinal = PagingMarker.ordinal(oldestBefore)
        let landedIndex = samples.indices.first { index in
            let sample = samples[index]
            let olderThanBefore = sample.oldestLoaded.map { PagingMarker.ordinal($0) < oldestOrdinal } ?? false
            let finishedLoading = index > 0 && samples[index - 1].olderState == "loading" && sample.olderState != "loading"
            return !sample.olderPresent || olderThanBefore || finishedLoading
        }
        guard let landedIndex else { return nil }
        let landedAt = samples[landedIndex].seconds
        let driftAfter = { (delay: TimeInterval) -> CGFloat? in
            samples[landedIndex...].first { $0.seconds >= landedAt + delay }?.drift(from: anchor)
        }
        return LandingMeasurement(
            gesture: gesture, style: style, oldestBefore: oldestBefore, landedAt: landedAt,
            driftAtLanding: samples[landedIndex].drift(from: anchor) ?? .infinity, driftAfter100ms: driftAfter(0.1),
            driftAfter1s: driftAfter(1), maxDrift: samples.maxDrift(from: anchor))
    }

    func test1PrependKeepsTheVisibleRowStill() throws {
        let (app, driver, _) = try openLongChat("bot-beta")
        shot(app, "prepend-0-opened-at-newest")
        var landings: [LandingMeasurement] = []
        var windows = 0
        var lostAnchorSamples = 0
        var maxDriftAnywhere: CGFloat = 0
        var oldestLoadedSeen: Set<String> = []
        var gestures = 0
        var flings = 0
        let deadline = Date().addingTimeInterval(Self.pagingBudget)
        while landings.count < Self.requiredLandings || flings < Self.requiredFlings, gestures < Self.maxGestures, Date() < deadline {
            let fast = gestures % 4 == 3
            gestures += 1
            if fast {
                flings += 1
                driver.flingOlder()
            } else {
                driver.dragOlder()
            }
            let reading = try driver.settled().reading
            guard let oldest = reading.oldestLoadedMarker else { continue }
            oldestLoadedSeen.insert(oldest)
            guard let anchor = driver.anchor(in: reading) else { continue }
            windows += 1
            let samples = try driver.observe(anchor, for: Self.landingWindow)
            lostAnchorSamples += samples.lostAnchorCount()
            maxDriftAnywhere = Swift.max(maxDriftAnywhere, samples.maxDrift(from: anchor))
            if let measured = landing(in: samples, anchor: anchor, oldestBefore: oldest, gesture: gestures, style: fast ? "fling" : "drag") {
                landings.append(measured)
                if landings.count == 1 { shot(app, "prepend-1-first-page-landed") }
            }
            if let landedOldest = samples.last?.oldestLoaded { oldestLoadedSeen.insert(landedOldest) }
        }
        shot(app, "prepend-2-after-paging")
        record([
            "gestures": gestures, "flings": flings, "observation_windows": windows,
            "measured_landings": landings.count, "distinct_oldest_loaded": oldestLoadedSeen.count,
            "max_drift_pt": PagingMeasurements.points(maxDriftAnywhere), "lost_anchor_samples": lostAnchorSamples,
            "tolerance_pt": PagingMeasurements.points(Self.driftTolerance), "landings": landings.map(\.json),
        ])
        XCTAssertGreaterThanOrEqual(landings.count, Self.requiredLandings, "pages landed inside an observation window after \(gestures) gestures")
        XCTAssertGreaterThanOrEqual(flings, Self.requiredFlings, "fast flings performed")
        XCTAssertEqual(lostAnchorSamples, 0, "the marked row stayed in the list during every observation")
        XCTAssertLessThanOrEqual(maxDriftAnywhere, Self.driftTolerance, "the marked row did not move while pages landed (worst drift in points)")
        let worstLanding = landings.map(\.maxDrift).max() ?? 0
        XCTAssertLessThanOrEqual(worstLanding, Self.driftTolerance, "drift around the landings themselves (points)")
    }

    func test2ScrollToTopReachesTheFirstMessageWithNoGapsOrHidden() throws {
        let profile = try manifest.profile("bot-alpha")
        let (app, driver, opened) = try openLongChat("bot-alpha")
        shot(app, "top-0-opened-at-newest")
        var seen = Set(opened.allMarkers)
        var hiddenSeen = Set(opened.hiddenMarkers)
        var duplicateReadings: [String] = []
        var previous = opened
        var stalled = 0
        var gestures = 0
        var reachedStart = false
        let started = Date()
        while !reachedStart {
            let elapsed = Date().timeIntervalSince(started)
            guard gestures < Self.scrollToTopMaxGestures, elapsed < Self.scrollToTopBudget else {
                XCTFail("scroll to top gave up after \(gestures) gestures and \(Int(elapsed)) s with \(seen.count) of \(profile.visibleCount) messages seen; oldest seen \(seen.sorted().first ?? "none")")
                break
            }
            driver.dragOlder()
            gestures += 1
            let reading = try driver.settled().reading
            let before = seen.count
            seen.formUnion(reading.allMarkers)
            hiddenSeen.formUnion(reading.hiddenMarkers)
            if !reading.duplicatedMarkers.isEmpty { duplicateReadings.append("gesture \(gestures): \(reading.duplicatedMarkers)") }
            let progressed = seen.count > before || !reading.sameLayout(as: previous)
            stalled = progressed ? 0 : stalled + 1
            previous = reading
            if stalled >= Self.stallGestures {
                XCTFail("scroll to top stalled for \(stalled) gestures at gesture \(gestures) with \(seen.count) of \(profile.visibleCount) messages seen; older row is \(reading.olderState ?? "absent"); oldest seen \(seen.sorted().first ?? "none")")
                break
            }
            reachedStart = reading.olderState == "start" && seen.contains(profile.firstVisibleMarker)
        }
        shot(app, "top-1-start-of-chat")
        let expected = Set(profile.visible)
        let missing = expected.subtracting(seen).sorted()
        let extra = seen.subtracting(expected).sorted()
        record([
            "gestures": gestures, "seconds": PagingMeasurements.seconds(Date().timeIntervalSince(started)),
            "expected": expected.count, "seen": seen.count, "missing": missing, "extra": extra,
            "hidden_seen": hiddenSeen.sorted(), "duplicate_readings": duplicateReadings, "reached_start": reachedStart,
        ])
        XCTAssertTrue(reachedStart, "the older row reports the start of the chat with the first message on screen")
        XCTAssertTrue(missing.isEmpty, "messages never seen while scrolling to the top (\(missing.count)): \(missing.prefix(20))")
        XCTAssertTrue(extra.isEmpty, "markers seen that are not in the seeded chat (\(extra.count)): \(extra.prefix(20))")
        XCTAssertTrue(hiddenSeen.isEmpty, "hidden rows must never be shown: \(hiddenSeen.sorted().prefix(20))")
        XCTAssertTrue(duplicateReadings.isEmpty, "a message showed up twice in one snapshot: \(duplicateReadings.prefix(10))")
    }

    func test3NewReplyWhileReadingDoesNotMoveAndShowsPill() throws {
        let (app, driver, _) = try openLongChat("bot-alpha")
        let prompt = "SLOW paging probe " + UUID().uuidString.prefix(6)
        send(app, prompt)
        waitFor(bubbles(app, "userBubble", containing: prompt).firstMatch, timeout: 15, "the sent prompt appears")
        for _ in 0..<4 { driver.dragOlder() }
        let reading = try driver.settled().reading
        let anchor = try XCTUnwrap(driver.anchor(in: reading), "a marked row is on screen after scrolling up")
        shot(app, "reply-0-reading-history")

        var samples: [AnchorSample] = []
        var pillFirstSeen: TimeInterval?
        let started = Date()
        while Date().timeIntervalSince(started) < 90 {
            let sample = try driver.sample(anchor, since: started)
            samples.append(sample)
            if sample.pillLabel != nil, pillFirstSeen == nil { pillFirstSeen = sample.seconds }
            if let pillFirstSeen, sample.seconds - pillFirstSeen >= Self.pillSettleSeconds { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        shot(app, "reply-1-pill-while-reading")
        let pillLabel = samples.last?.pillLabel ?? ""
        let unreadCount = Int(pillLabel.prefix { $0.isNumber }) ?? 0
        let drift = samples.maxDrift(from: anchor)
        record([
            "samples": samples.count, "max_drift_pt": PagingMeasurements.points(drift),
            "lost_anchor_samples": samples.lostAnchorCount(), "pill_label": pillLabel, "unread_count": unreadCount,
            "pill_first_seen_s": pillFirstSeen.map(PagingMeasurements.seconds) ?? -1,
        ])
        XCTAssertEqual(samples.lostAnchorCount(), 0, "the marked row stayed in the list while the reply streamed")
        XCTAssertLessThanOrEqual(drift, Self.driftTolerance, "the marked row did not move while the reply arrived (worst drift in points)")
        XCTAssertNotNil(pillFirstSeen, "the jump pill appeared while the reply arrived")
        XCTAssertGreaterThanOrEqual(unreadCount, 1, "the pill counts the new reply, label was \(pillLabel)")

        let pill = element(app, "scrollToBottomButton")
        waitFor(pill, timeout: 5, "jump pill is still there")
        pill.tap()
        let reply = bubbles(app, "assistantBubble", containing: "slow-39").firstMatch
        waitFor(reply, timeout: 30, "the finished reply is on screen after the jump")
        waitGone(element(app, "thinkingLine"), timeout: 60, "thinking row ends with the reply")
        waitGone(pill, timeout: 10, "the pill goes away at the bottom")
        let composer = element(app, "composerField")
        XCTAssertTrue(reply.isHittable, "the newest reply is visible")
        XCTAssertLessThanOrEqual(reply.frame.maxY, composer.frame.minY, "the end of the newest reply sits above the composer")
        shot(app, "reply-2-after-jump")
    }

    func test4CacheToLiveOpenDoesNotShrinkOrJump() throws {
        let profile = try manifest.profile("bot-beta")
        var (app, driver, _) = try openLongChat("bot-beta")
        let paged = try driver.pageUp(landings: 3)
        shot(app, "cache-0-paged-before-leaving")
        XCTAssertGreaterThanOrEqual(paged.landings, 3, "pages landed before leaving the chat")
        goBack(app)
        XCTAssertTrue(roster(app).waitForExistence(timeout: 15), "roster after leaving the chat")
        app.terminate()

        app = signedInApp()
        driver = PagingDriver(app: app)
        let row = app.buttons["botRow-bot-beta"]
        waitFor(row, timeout: 30, "roster row after relaunch")
        row.hit()

        var first = try driver.read()
        let contentDeadline = Date().addingTimeInterval(60)
        while first.onScreen.isEmpty, Date() < contentDeadline {
            Thread.sleep(forTimeInterval: 0.05)
            first = try driver.read()
        }
        XCTAssertFalse(first.onScreen.isEmpty, "the reopened chat showed content")
        let bottom = try XCTUnwrap(first.bottomMostBubble?.marker, "a bottom-most marked row at first content")
        let anchor = PagingAnchor(marker: bottom, y: first.minY(of: bottom) ?? 0)
        var shrinks: [String] = []
        var previousCount = first.onScreen.count
        var maxCount = previousCount
        var samples: [AnchorSample] = []
        var newestOnScreen = first.allMarkers.contains(profile.newestVisibleMarker)
        let started = Date()
        while Date().timeIntervalSince(started) < Self.openSampleSeconds {
            let reading = try driver.read()
            let elapsed = Date().timeIntervalSince(started)
            let count = reading.onScreen.count
            if count < previousCount { shrinks.append("\(PagingMeasurements.seconds(elapsed)) s: \(previousCount) to \(count)") }
            previousCount = count
            maxCount = Swift.max(maxCount, count)
            newestOnScreen = newestOnScreen || reading.allMarkers.contains(profile.newestVisibleMarker)
            samples.append(AnchorSample(
                seconds: elapsed, anchorY: reading.minY(of: anchor.marker), olderState: reading.olderState,
                olderPresent: reading.olderFrame != nil, oldestLoaded: reading.oldestLoadedMarker, pillLabel: reading.pillLabel))
            Thread.sleep(forTimeInterval: 0.1)
        }
        shot(app, "cache-1-reopened-live")
        let drift = samples.maxDrift(from: anchor)
        record([
            "samples": samples.count, "bottom_marker": bottom, "first_content_rows": first.onScreen.count, "max_rows": maxCount,
            "shrinks": shrinks, "max_drift_pt": PagingMeasurements.points(drift), "lost_anchor_samples": samples.lostAnchorCount(),
            "newest_marker_seen": newestOnScreen, "pages_before_leaving": paged.landings,
        ])
        XCTAssertTrue(shrinks.isEmpty, "the rows on screen never shrank after first content: \(shrinks)")
        XCTAssertEqual(samples.lostAnchorCount(), 0, "the bottom-most row stayed in the list")
        XCTAssertLessThanOrEqual(drift, Self.driftTolerance, "the bottom-most row did not move after content first appeared (worst drift in points)")
        XCTAssertTrue(newestOnScreen, "the reopened chat shows the newest message \(profile.newestVisibleMarker)")
    }

    func test5ReconnectWhileReadingKeepsHistoryAndPosition() throws {
        let (app, driver, _) = try openLongChat("bot-beta")
        let paged = try driver.pageUp(landings: 3)
        XCTAssertGreaterThanOrEqual(paged.landings, 3, "pages landed before the gateway went away")
        let witness = try XCTUnwrap(paged.oldestSeenMarker, "an oldest loaded message was seen")
        driver.leaveTopBoundary()
        let quiet = try driver.quiesce()
        let anchor = try XCTUnwrap(driver.anchor(in: quiet), "a marked row is on screen before the outage")
        shot(app, "reconnect-0-before-outage")

        var samples = try driver.observe(anchor, for: 3)
        try control("kill-gateway")
        samples += try driver.observe(anchor, for: Self.reconnectOutageSeconds)
        shot(app, "reconnect-1-during-outage")
        try control("start-gateway")
        samples += try driver.observe(anchor, for: Self.reconnectObservedSeconds)
        shot(app, "reconnect-2-after-restart")

        let drift = samples.maxDrift(from: anchor)
        let reach = try driver.reach(witness, maxDrags: 15)
        shot(app, "reconnect-3-oldest-loaded-reached")

        let pill = element(app, "scrollToBottomButton")
        if pill.waitForExistence(timeout: 5) {
            pill.tap()
        } else {
            for _ in 0..<6 { driver.flingNewer() }
        }
        waitGone(element(app, "reconnectingIndicator"), timeout: 60, "the chat is connected again at the bottom")
        record([
            "samples": samples.count, "max_drift_pt": PagingMeasurements.points(drift), "lost_anchor_samples": samples.lostAnchorCount(),
            "pages_before_outage": paged.landings, "witness_marker": witness, "witness_reach": reach.rawValue,
        ])
        XCTAssertEqual(samples.lostAnchorCount(), 0, "the marked row stayed in the list through the outage and the reconnect")
        XCTAssertLessThanOrEqual(drift, Self.driftTolerance, "the marked row did not move through the outage and the reconnect (worst drift in points)")
        XCTAssertEqual(reach, .found, "the oldest message loaded before the outage is still in the list without paging again")
    }
}
