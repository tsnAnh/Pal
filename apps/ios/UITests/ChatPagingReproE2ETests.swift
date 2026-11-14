import XCTest

@MainActor
final class ChatPagingReproE2ETests: BotProfileTestCase {
    private static let bundleID = "dev.tsnanh.hermes.bot"
    private static let markerPattern = try! NSRegularExpression(pattern: "\u{27E6}(\\d{4})\u{27E7}")
    private static let rowIdentifiers: Set<String> = ["userBubble", "assistantBubble"]
    private static let statusIdentifiers: Set<String> = [
        "assistantBubble-streaming", "reconnectingIndicator", "chatStatusLine", "timeSeparator", "unreadDivider",
        "chatImageGrid", "chatImageLoading", "chatImageFailed", "scrollToBottom",
    ]

    private struct Node {
        let identifier: String
        let marker: Int?
        let y: Double
        let height: Double
        let labelLength: Int
    }

    private func orNull(_ value: Any?) -> Any { value ?? NSNull() }

    private var scenario = ""
    private let epoch = Date()

    override func setUp() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["HERMES_UITEST_SEED"] == "perf", "needs the long Bot Chats seeded with --mix rich and HERMES_UITEST_SEED=perf")
        #if os(macOS)
        throw XCTSkip("drives the iOS simulator")
        #endif
        try await super.setUp()
    }

    private func controlDirectory() throws -> String {
        try XCTUnwrap(ProcessInfo.processInfo.environment["HERMES_PAGING_BOUNCE_DIR"], "HERMES_PAGING_BOUNCE_DIR not set")
    }

    private func chatCacheFiles() -> [URL] {
        let containers = URL(fileURLWithPath: NSHomeDirectory()).deletingLastPathComponent()
        let entries = (try? FileManager.default.contentsOfDirectory(at: containers, includingPropertiesForKeys: nil)) ?? []
        for entry in entries {
            let metadata = entry.appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist")
            guard let data = try? Data(contentsOf: metadata),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  plist["MCMMetadataIdentifier"] as? String == Self.bundleID
            else { continue }
            let cache = entry.appendingPathComponent("Library/Application Support/cache")
            let accounts = (try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)) ?? []
            return accounts.flatMap { account in
                ((try? FileManager.default.contentsOfDirectory(at: account, includingPropertiesForKeys: nil)) ?? [])
                    .filter { $0.lastPathComponent.hasPrefix("chat-") }
            }
        }
        return []
    }

    private func clearChatCaches() {
        for file in chatCacheFiles() { try? FileManager.default.removeItem(at: file) }
    }

    private func collect(_ snapshot: XCUIElementSnapshot, into rows: inout [Node], status: inout [String: Int]) {
        let identifier = snapshot.identifier
        if Self.rowIdentifiers.contains(identifier) {
            let label = snapshot.label
            let range = NSRange(label.startIndex..., in: label)
            let marker = Self.markerPattern.firstMatch(in: label, range: range)
                .flatMap { Range($0.range(at: 1), in: label) }
                .flatMap { Int(label[$0]) }
            rows.append(Node(identifier: identifier, marker: marker, y: snapshot.frame.minY, height: snapshot.frame.height, labelLength: label.count))
        } else if Self.statusIdentifiers.contains(identifier) {
            status[identifier, default: 0] += 1
        }
        for child in snapshot.children { collect(child, into: &rows, status: &status) }
    }

    @discardableResult
    private func dump(_ app: XCUIApplication, _ step: String, _ extra: [String: Any] = [:]) -> [Node] {
        let started = Date()
        var rows: [Node] = []
        var status: [String: Int] = [:]
        var screen = CGRect.zero
        if let snapshot = try? app.snapshot() {
            screen = snapshot.frame
            collect(snapshot, into: &rows, status: &status)
        }
        let record: [String: Any] = [
            "t": Date().timeIntervalSince(epoch), "snapshotSeconds": Date().timeIntervalSince(started), "scenario": scenario, "step": step,
            "screenHeight": screen.height,
            "rows": rows.map { ["id": $0.identifier, "marker": orNull($0.marker), "y": $0.y, "h": $0.height, "len": $0.labelLength] },
            "status": status,
        ].merging(extra) { current, _ in current }
        append(record)
        return rows
    }

    private func append(_ record: [String: Any]) {
        guard let directory = env.shotsDirectory,
              let data = try? JSONSerialization.data(withJSONObject: record, options: [.fragmentsAllowed]) else { return }
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let path = directory + "/paging-dump-\(scenario).jsonl"
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        handle.seekToEndOfFile()
        handle.write(data)
        handle.write(Data("\n".utf8))
        try? handle.close()
    }

    private func event(_ name: String, _ extra: [String: Any] = [:]) {
        append(["t": Date().timeIntervalSince(epoch), "scenario": scenario, "event": name].merging(extra) { current, _ in current })
    }

    private func signature(_ rows: [Node]) -> [String] {
        rows.map { "\($0.marker ?? -1):\(Int($0.y.rounded()))" }
    }

    private func drag(_ app: XCUIApplication, down: Bool) {
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: down ? 0.22 : 0.80))
        let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: down ? 0.80 : 0.22))
        from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .default, thenHoldForDuration: 0.3)
    }

    @discardableResult
    private func settle(_ app: XCUIApplication, _ step: String, nearTopWait: TimeInterval = 3.0, quietWait: TimeInterval = 0.8, maxWait: TimeInterval = 8) -> [Node] {
        let started = Date()
        var previous: [String] = []
        var rows: [Node] = []
        var sample = 0
        while true {
            rows = dump(app, step, ["sample": sample])
            sample += 1
            let nearTop = (rows.first?.y ?? -10_000) > -1_200
            let elapsed = Date().timeIntervalSince(started)
            let stable = signature(rows) == previous
            if stable, elapsed >= (nearTop ? nearTopWait : quietWait) { break }
            if elapsed >= maxWait { break }
            previous = signature(rows)
        }
        return rows
    }

    private func openChat(_ app: XCUIApplication, _ bot: String, watch seconds: TimeInterval, step: String) {
        let row = app.buttons["botRow-\(bot)"]
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        event("tap-bot", ["bot": bot])
        row.hit()
        let started = Date()
        var firstBubble: TimeInterval?
        var sample = 0
        while Date().timeIntervalSince(started) < seconds {
            let rows = dump(app, step, ["sample": sample, "sinceTap": Date().timeIntervalSince(started)])
            sample += 1
            if firstBubble == nil, !rows.isEmpty { firstBubble = Date().timeIntervalSince(started) }
        }
        event("open-watch-finished", ["firstBubbleSeconds": orNull(firstBubble)])
    }

    private func leaveChat(_ app: XCUIApplication) {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: 10))
        back.hit()
        XCTAssertTrue(roster(app).waitForExistence(timeout: 20))
    }

    private func scrollUp(_ app: XCUIApplication, swipes: Int, label: String) {
        for index in 0..<swipes {
            settle(app, "\(label)-before-\(index)", nearTopWait: 0.8)
            event("swipe", ["index": index, "direction": "down", "label": label])
            drag(app, down: true)
        }
    }

    func test1ColdFullScanToTop() throws {
        scenario = "cold-full-scan"
        clearChatCaches()
        let app = signedInApp()
        openChat(app, "bot-beta", watch: 8, step: "open")
        shot(app, "scan-0-opened")
        var unchanged = 0
        var lastTop: Int?
        let deadline = Date().addingTimeInterval(40 * 60)
        var swipes = 0
        var wiggles = 0
        var fruitlessWiggles = 0
        var rowsAtWiggle = 0
        while fruitlessWiggles < 4, swipes < 900, Date() < deadline {
            let rows = settle(app, "pre-swipe-\(swipes)", nearTopWait: 3.0)
            let top = rows.compactMap(\.marker).min()
            let topY = rows.first?.y ?? -10_000
            if top == lastTop, topY > -50 { unchanged += 1 } else { unchanged = 0 }
            lastTop = top
            if unchanged >= 3 {
                wiggles += 1
                fruitlessWiggles = rows.count > rowsAtWiggle ? 0 : fruitlessWiggles + 1
                rowsAtWiggle = rows.count
                event("wiggle", ["index": wiggles, "rowCount": rows.count, "topMarker": orNull(top)])
                for _ in 0..<3 { drag(app, down: false) }
                unchanged = 0
                continue
            }
            event("swipe", ["index": swipes, "direction": "down"])
            drag(app, down: true)
            swipes += 1
            if swipes == 20 || swipes == 100 { shot(app, "scan-\(swipes)") }
        }
        let finalRows = settle(app, "final", nearTopWait: 5)
        event("scan-finished", ["swipes": swipes, "topMarker": orNull(finalRows.compactMap(\.marker).min())])
        shot(app, "scan-final-top")
    }

    func test2ColdThenWarmOpen() throws {
        scenario = "cold-vs-warm-open"
        clearChatCaches()
        let app = signedInApp()
        event("phase", ["name": "cold"])
        openChat(app, "bot-alpha", watch: 10, step: "cold-open")
        shot(app, "open-cold")
        scrollUp(app, swipes: 6, label: "cold-scroll")
        settle(app, "cold-after-scroll")
        event("cache-files", ["count": chatCacheFiles().count])
        leaveChat(app)
        Thread.sleep(forTimeInterval: 2)
        event("phase", ["name": "warm"])
        openChat(app, "bot-alpha", watch: 10, step: "warm-open")
        shot(app, "open-warm")
        scrollUp(app, swipes: 6, label: "warm-scroll")
        settle(app, "warm-after-scroll")
    }

    func test3ReconnectWhileScrolledUp() throws {
        scenario = "reconnect-scrolled-up"
        let directory = try controlDirectory()
        let request = directory + "/bounce-request"
        let ack = directory + "/bounce-ack"
        try? FileManager.default.removeItem(atPath: request)
        try? FileManager.default.removeItem(atPath: ack)
        clearChatCaches()
        let app = signedInApp()
        openChat(app, "bot-alpha", watch: 6, step: "open")
        scrollUp(app, swipes: 14, label: "pre-bounce")
        let before = settle(app, "pre-bounce-settled", nearTopWait: 3)
        shot(app, "reconnect-0-before")
        event("bounce-request", ["topMarker": orNull(before.compactMap(\.marker).min())])
        FileManager.default.createFile(atPath: request, contents: Data("go".utf8))
        let deadline = Date().addingTimeInterval(150)
        var acked: Date?
        var shotTaken = false
        while Date() < deadline {
            let rows = dump(app, "during-bounce", ["acked": acked != nil])
            if !shotTaken, app.descendants(matching: .any)["reconnectingIndicator"].exists { shot(app, "reconnect-1-indicator"); shotTaken = true }
            if acked == nil, FileManager.default.fileExists(atPath: ack) { acked = Date(); event("bounce-acked") }
            if let acked, Date().timeIntervalSince(acked) > 30, !rows.isEmpty { break }
        }
        let after = settle(app, "post-bounce-settled", nearTopWait: 4)
        shot(app, "reconnect-2-after")
        event("bounce-finished", ["topMarker": orNull(after.compactMap(\.marker).min())])
        scrollUp(app, swipes: 8, label: "post-bounce")
        settle(app, "post-bounce-after-scroll")
    }

    func test5ReconnectMidListAfterOlderPagesLoaded() throws {
        scenario = "reconnect-mid-list"
        let directory = try controlDirectory()
        let request = directory + "/bounce-request"
        let ack = directory + "/bounce-ack"
        try? FileManager.default.removeItem(atPath: request)
        try? FileManager.default.removeItem(atPath: ack)
        clearChatCaches()
        let app = signedInApp()
        openChat(app, "bot-alpha", watch: 4, step: "open")
        var unchanged = 0
        var lastTop: Int?
        var swipes = 0
        var rowCount = 0
        while rowCount < 180, swipes < 120 {
            let rows = settle(app, "load-\(swipes)", nearTopWait: 3.0)
            rowCount = rows.count
            let top = rows.compactMap(\.marker).min()
            if top == lastTop, (rows.first?.y ?? -10_000) > -50 { unchanged += 1 } else { unchanged = 0 }
            lastTop = top
            if unchanged >= 3 {
                event("wiggle", ["rowCount": rows.count, "topMarker": orNull(top)])
                for _ in 0..<3 { drag(app, down: false) }
                unchanged = 0
                continue
            }
            event("swipe", ["index": swipes, "direction": "down"])
            drag(app, down: true)
            swipes += 1
        }
        for index in 0..<3 {
            settle(app, "mid-\(index)", nearTopWait: 0.8)
            event("swipe", ["index": index, "direction": "up", "label": "mid"])
            drag(app, down: false)
        }
        let before = settle(app, "pre-bounce-settled", nearTopWait: 2)
        shot(app, "reconnect-mid-0-before")
        event("bounce-request", ["rowCount": before.count, "topMarker": orNull(before.compactMap(\.marker).min())])
        FileManager.default.createFile(atPath: request, contents: Data("go".utf8))
        let deadline = Date().addingTimeInterval(200)
        var acked: Date?
        var shotTaken = false
        while Date() < deadline {
            let rows = dump(app, "during-bounce", ["acked": acked != nil])
            if !shotTaken, app.descendants(matching: .any)["reconnectingIndicator"].exists { shot(app, "reconnect-mid-1-indicator"); shotTaken = true }
            if acked == nil, FileManager.default.fileExists(atPath: ack) { acked = Date(); event("bounce-acked") }
            if let acked, Date().timeIntervalSince(acked) > 25, !rows.isEmpty { break }
        }
        let after = settle(app, "post-bounce-settled", nearTopWait: 4)
        shot(app, "reconnect-mid-2-after")
        event("bounce-finished", ["rowCount": after.count, "topMarker": orNull(after.compactMap(\.marker).min())])
        for index in 0..<6 {
            settle(app, "post-\(index)", nearTopWait: 0.8)
            event("swipe", ["index": index, "direction": "down", "label": "post"])
            drag(app, down: true)
        }
        settle(app, "post-final", nearTopWait: 4)
    }

    func test4FindOldMessageThenScrollDown() throws {
        scenario = "find-then-scroll-down"
        let environment = ProcessInfo.processInfo.environment
        let findText = try XCTUnwrap(environment["HERMES_PAGING_FIND_TEXT"], "HERMES_PAGING_FIND_TEXT not set")
        clearChatCaches()
        let app = signedInApp()
        openChat(app, "bot-alpha", watch: 6, step: "open")
        app.buttons["chatMenuButton"].tap()
        waitFor(app.buttons["chatMenuFind"], timeout: 10, "overflow menu")
        app.buttons["chatMenuFind"].tap()
        let field = app.textFields["findField"]
        waitFor(field, timeout: 10, "find field")
        field.typeText(findText)
        event("find-typed", ["text": findText])
        let count = element(app, "findCount")
        waitFor(count, timeout: 30, "match counter")
        let started = Date()
        var lastLabel = ""
        while Date().timeIntervalSince(started) < 90 {
            let rows = dump(app, "find-wait", ["findCount": count.label])
            if count.label != lastLabel { lastLabel = count.label; event("find-count", ["label": lastLabel, "rowCount": rows.count]) }
            if count.label != "No results", !count.label.isEmpty, Date().timeIntervalSince(started) > 4 { break }
        }
        let found = settle(app, "find-landed", nearTopWait: 4)
        shot(app, "find-0-landed")
        event("find-landed", ["rowCount": found.count, "topMarker": orNull(found.compactMap(\.marker).min())])
        let done = app.buttons["findDone"]
        if done.exists { done.tap() }
        for index in 0..<45 {
            settle(app, "down-before-\(index)", nearTopWait: 0.8)
            event("swipe", ["index": index, "direction": "up"])
            drag(app, down: false)
        }
        settle(app, "down-final")
        shot(app, "find-1-after-scroll-down")
    }
}
