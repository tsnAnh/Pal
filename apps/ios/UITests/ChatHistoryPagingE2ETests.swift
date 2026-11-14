import XCTest

@MainActor
final class ChatHistoryPagingE2ETests: BotProfileTestCase {
    private static let longBot = "bot-beta"

    private var olderText = ""
    private var findText = ""

    override func setUp() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["HERMES_UITEST_SEED"] == "perf", "needs the long Bot Chats seeded by apps/ios/Tools/perf/run-baseline and HERMES_UITEST_SEED=perf")
        #if os(macOS)
        throw XCTSkip("drives the iOS simulator")
        #endif
        olderText = environment["HERMES_PERF_OLDER_TEXT"] ?? ""
        findText = environment["HERMES_PERF_FIND_TEXT"] ?? ""
        try XCTSkipIf(olderText.isEmpty || findText.isEmpty, "needs HERMES_PERF_OLDER_TEXT and HERMES_PERF_FIND_TEXT from the seeded history")
        try await super.setUp()
    }

    private func transcriptRows(_ app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier IN %@", ["userBubble", "assistantBubble"]))
    }

    func test1ScrollToTopPagesOlderHistoryWithoutJumping() throws {
        let app = signedInApp()
        openBot(app, Self.longBot)
        waitFor(transcriptRows(app).firstMatch, timeout: 60, "transcript content")
        Thread.sleep(forTimeInterval: 2)
        let initialRows = transcriptRows(app).count
        let older = bubbles(app, "assistantBubble", containing: olderText).firstMatch
        XCTAssertFalse(older.exists, "older text is not in the opening window")
        shot(app, "paging-0-opened-at-newest")

        var swipes = 0
        var rowsBeforeLanding = initialRows
        while !older.exists, swipes < 60 {
            rowsBeforeLanding = transcriptRows(app).count
            app.swipeDown(velocity: .fast)
            swipes += 1
            if swipes.isMultiple(of: 10) { print("paging-progress swipes=\(swipes) rows=\(transcriptRows(app).count)") }
        }
        XCTAssertTrue(older.exists, "an older seeded message appears after scrolling up \(swipes) times")
        let landedY = older.frame.minY
        shot(app, "paging-1-older-message-loaded")
        Thread.sleep(forTimeInterval: 2)
        let settledY = older.frame.minY
        shot(app, "paging-2-after-settle")
        let grownRows = transcriptRows(app).count
        print("paging-evidence initialRows=\(initialRows) rowsBeforeLanding=\(rowsBeforeLanding) grownRows=\(grownRows) swipes=\(swipes) landedY=\(landedY) settledY=\(settledY)")
        XCTAssertGreaterThan(grownRows, initialRows, "row count grows after paging older history")
        XCTAssertEqual(landedY, settledY, accuracy: 2, "no jump after the page lands")
    }

    func test2FindInChatReachesTheOldestMessages() throws {
        let app = signedInApp()
        openBot(app, Self.longBot)
        waitFor(transcriptRows(app).firstMatch, timeout: 60, "transcript content")
        app.buttons["chatMenuButton"].tap()
        waitFor(app.buttons["chatMenuFind"], timeout: 10, "overflow menu")
        app.buttons["chatMenuFind"].tap()
        let field = app.textFields["findField"]
        waitFor(field, timeout: 10, "find field")
        field.typeText(findText)
        let count = element(app, "findCount")
        waitFor(count, timeout: 30, "match counter")
        let deadline = Date().addingTimeInterval(60)
        while count.label == "No results" || count.label.isEmpty, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertNotEqual(count.label, "No results", "find reaches text that exists only in the oldest messages")
        XCTAssertTrue(bubbles(app, "assistantBubble", containing: findText).firstMatch.waitForExistence(timeout: 10), "the oldest match is in the transcript")
        shot(app, "find-oldest-match")
    }

    func test3RoutinesReopenShowsCachedContentWithoutSpinner() throws {
        let app = signedInApp()
        let loaded = NSPredicate(format: "identifier IN %@", ["routinesEmpty", "routinesCard"])
        openProfile(app, Self.longBot)
        element(app, "profileRoutinesRow").tap()
        waitFor(element(app, "routinesScreen"), timeout: 20, "routines screen")
        waitFor(app.descendants(matching: .any).matching(loaded).firstMatch, timeout: 30, "routines content first open")
        shot(app, "routines-first-open")
        goBack(app)

        waitFor(element(app, "profileRoutinesRow"), timeout: 10, "profile again")
        element(app, "profileRoutinesRow").tap()
        waitFor(element(app, "routinesScreen"), timeout: 10, "routines screen second open")
        XCTAssertTrue(app.descendants(matching: .any).matching(loaded).firstMatch.exists, "cached routines show at once on the second open")
        var spinnerSeen = false
        for _ in 0..<10 {
            if element(app, "routinesLoading").exists { spinnerSeen = true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertFalse(spinnerSeen, "no loading spinner on the second open")
        shot(app, "routines-second-open")
    }
}
