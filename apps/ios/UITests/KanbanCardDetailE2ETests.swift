import XCTest

@MainActor
final class KanbanCardDetailE2ETests: KanbanE2ETestCase {
    private let readyTitle = "Write release notes"

    private func openReadyCard(_ app: XCUIApplication) {
        let entry = app.buttons["kanbanButton"]
        waitFor(entry, timeout: 20, "work boards button")
        entry.hit()
        openSeededBoard(app)
        show(app, column: "ready")
        let row = card(app, in: "ready")
        waitFor(row, timeout: 20, "the card in Ready")
        row.hit()
        waitFor(any(app, "kanbanBody"), timeout: 20, "card detail ticket")
    }

    private func text(of element: XCUIElement) -> String {
        element.label.isEmpty ? (element.value as? String ?? "") : element.label
    }

    private func waitForLabel(_ element: XCUIElement, _ label: String, _ message: String, timeout: TimeInterval = 10) {
        let matches = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: element)
        XCTAssertEqual(XCTWaiter().wait(for: [matches], timeout: timeout), .completed, "\(message): saw \(element.label)")
    }

    private func waitUntilGone(_ element: XCUIElement, _ message: String, timeout: TimeInterval = 10) {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: timeout), .completed, message)
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 where !(element.exists && element.isHittable) { any(app, "kanbanCard").swipeUp() }
    }

    private func ticketParts(_ app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@ AND NOT identifier ENDSWITH %@", "kanbanPart-", "-caption"))
    }

    private func evidenceRows(_ app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier MATCHES %@", "kanbanEvidence-[0-9]+"))
    }

    func testCardShowsOneTitleAndACopyableRef() throws {
        try control("kanban-seed")
        let app = launch()
        signInIfNeeded(app)
        openReadyCard(app)

        XCTAssertFalse(any(app, "kanbanCardTitle").exists, "the body no longer repeats the title")
        let isTitle = NSPredicate(format: "label == %@", readyTitle)
        var titles = any(app, "kanbanCard").staticTexts.matching(isTitle).count
        #if os(iOS)
        titles += app.navigationBars.staticTexts.matching(isTitle).count
        #endif
        XCTAssertEqual(titles, 1, "the open card shows its title once")

        let ref = any(app, "kanbanRef")
        waitFor(ref, timeout: 10, "the card shows its ref")
        XCTAssertEqual(text(of: ref), "PAL-12", "the ref reads as the card's short name")
        let copy = any(app, "kanbanRefCopy")
        XCTAssertEqual(copy.label, "Copy", "the copy control starts as Copy")
        copy.hit()
        waitForLabel(copy, "Copied", "Copy confirms the copy")
        screenShot("kanban-card-ref")
    }

    func testTicketShowsOnlyLabelledPartsAndNoDetails() throws {
        try control("kanban-seed")
        let app = launch()
        signInIfNeeded(app)
        openReadyCard(app)

        waitFor(any(app, "kanbanPart-goal"), timeout: 10, "the Goal part")
        waitFor(any(app, "kanbanPart-done-means"), timeout: 10, "the Done means part")
        waitFor(any(app, "kanbanPart-owner-decisions"), timeout: 10, "the Owner decisions part")
        XCTAssertEqual(ticketParts(app).count, 3, "only labels present in the ticket get a part")
        XCTAssertFalse(any(app, "kanbanBodyIntro").exists, "the title line is dropped, so this card has no intro")
        XCTAssertFalse(any(app, "kanbanPart-current-status").exists, "an absent label has no heading")
        XCTAssertFalse(any(app, "kanbanPart-pull-requests").exists, "an absent label has no heading")
        XCTAssertFalse(app.staticTexts["Current status"].exists, "no empty Current status caption")
        XCTAssertTrue(app.staticTexts["thank the testers"].exists, "bullets keep their text")

        for _ in 0..<6 { any(app, "kanbanCard").swipeUp() }
        XCTAssertFalse(any(app, "kanbanDetails-toggle").exists, "the card has no Details control")
        XCTAssertFalse(any(app, "kanbanDetails").exists, "the card has no Details section")
        XCTAssertFalse(app.staticTexts["Key: PAL-1"].exists, "machine lines never show")
        XCTAssertFalse(app.staticTexts["Ref: PAL-12"].exists, "the ref line stays out of the ticket body")
        screenShot("kanban-card-bottom")
    }

    func testEvidenceCollapsesRepeatsAndShowsAllOnRequest() throws {
        try control("kanban-seed")
        let app = launch()
        signInIfNeeded(app)

        let entry = app.buttons["kanbanButton"]
        waitFor(entry, timeout: 20, "work boards button")
        entry.hit()
        openSeededBoard(app)
        show(app, column: "done")
        let merged = any(app, "kanbanColumn-done").buttons
            .matching(NSPredicate(format: "label CONTAINS %@", "Publish the docs")).firstMatch
        waitFor(merged, timeout: 20, "the finished card in Done")
        merged.hit()
        waitFor(any(app, "kanbanEvidence"), timeout: 20, "the evidence section")

        XCTAssertEqual(evidenceRows(app).count, 3, "evidence starts at three rows")
        let repeated = evidenceRows(app).matching(NSPredicate(format: "label CONTAINS %@", "\u{00D7}4"))
        XCTAssertGreaterThan(repeated.count, 0, "repeated proof collapses into one row with its count")
        let showAll = any(app, "kanbanEvidenceShowAll")
        reveal(showAll, in: app)
        showAll.hit()
        waitUntilGone(showAll, "Show all disappears once everything shows")
        XCTAssertGreaterThan(evidenceRows(app).count, 3, "Show all reveals the remaining rows")
        screenShot("kanban-card-evidence")
    }

    func testBoardSearchFindsACardByItsRef() throws {
        try control("kanban-seed")
        let app = launch()
        signInIfNeeded(app)

        let entry = app.buttons["kanbanButton"]
        waitFor(entry, timeout: 20, "work boards button")
        entry.hit()
        openSeededBoard(app)
        show(app, column: "ready")
        let row = card(app, in: "ready")
        waitFor(row, timeout: 20, "the card in Ready")
        XCTAssertTrue(row.label.contains("PAL-12"), "the tile carries the ref")

        let search = any(app, "kanbanSearch")
        search.hit()
        search.typeText("pal12")
        waitFor(card(app, in: "ready"), timeout: 10, "searching the ref without a dash finds the card")

        search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 5))
        search.typeText("PAL-99")
        waitUntilGone(card(app, in: "ready"), "an unknown ref finds nothing")
    }

    func testCardClosesTheWayThePlatformExpects() throws {
        try control("kanban-seed")
        let app = launch()
        signInIfNeeded(app)
        openReadyCard(app)

        #if os(macOS)
        let close = any(app, "kanbanCard-close")
        waitFor(close, timeout: 10, "the pane close control")
        close.hit()
        waitUntilGone(any(app, "kanbanBody"), "closing the pane clears the card")
        #else
        XCTAssertFalse(any(app, "kanbanCard-close").exists, "the pushed page has no second close control")
        let back = systemBack(app)
        let heading = app.navigationBars.staticTexts[readyTitle]
        waitFor(heading, timeout: 10, "the page title sits in the navigation bar")
        XCTAssertLessThan(back.frame.minX, heading.frame.minX, "the system Back is the leading control")
        #endif
    }

    #if os(iOS)
    func testWideBoardPaneClosesWithItsSystemCloseAndByTappingTheCardAgain() throws {
        try control("kanban-seed")
        let app = launch()
        signInIfNeeded(app)

        let entry = app.buttons["kanbanButton"]
        waitFor(entry, timeout: 20, "work boards button")
        entry.hit()
        openSeededBoard(app)
        try XCTSkipIf(app.buttons["kanbanColumns-ready"].exists, "this device is compact: no side pane")
        let row = any(app, "kanbanColumn-backlog").buttons.firstMatch
        waitFor(row, timeout: 20, "a card in Backlog")
        let close = app.buttons["kanbanCard-close"]
        row.hit()
        waitFor(close, timeout: 20, "the card pane opens beside the board")
        XCTAssertEqual(close.label, "Close", "the pane close is the system close")
        shot(app, "kanban-pane-open")
        close.hit()
        waitUntilGone(close, "closing the pane removes it")
        shot(app, "kanban-pane-closed")

        row.hit()
        waitFor(close, timeout: 20, "the pane reopens")
        row.hit()
        waitUntilGone(close, "tapping the selected card again closes the pane")
    }
    #endif

    private func assertOneWayOut(_ app: XCUIApplication, close: Bool, _ screen: String) {
        for duplicate in ["kanbanBoards-back", "kanbanBoards-close", "kanbanBoard-back", "kanbanCard-close", "kanban-close"] {
            XCTAssertFalse(any(app, duplicate).exists, "\(screen) has no \(duplicate)")
        }
        XCTAssertEqual(app.buttons.matching(identifier: "kanbanBoard-close").count, close ? 1 : 0, "\(screen) close count")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == 'Close'")).count, close ? 1 : 0, "\(screen) has \(close ? "one" : "no") close")
    }

    func testEachScreenHasOneSystemWayOut() throws {
        try control("kanban-seed")
        let app = launch()
        signInIfNeeded(app)

        let entry = app.buttons["kanbanButton"]
        waitFor(entry, timeout: 20, "work boards button")
        entry.hit()
        openSeededBoard(app)
        assertOneWayOut(app, close: !pushesKanban, "board")
        show(app, column: "ready")
        let row = card(app, in: "ready")
        waitFor(row, timeout: 20, "the card in Ready")

        #if os(iOS)
        row.hit()
        waitFor(any(app, "kanbanBody"), timeout: 20, "card detail")
        assertOneWayOut(app, close: false, "card detail")

        systemBack(app).hit()
        waitFor(any(app, "kanbanBoard"), timeout: 20, "back from the card lands on the board")
        XCTAssertFalse(any(app, "kanbanBody").exists, "the card detail is gone")
        #endif

        #if os(iOS)
        if pushesKanban {
            let heading = app.navigationBars["Pal Kanban"]
            waitFor(heading, timeout: 10, "the board title sits in the navigation bar")
            XCTAssertLessThan(systemBack(app).frame.minX, heading.staticTexts["Pal Kanban"].frame.minX, "the system Back leads the board bar")
            systemBack(app).hit()
        } else {
            app.buttons["kanbanBoard-close"].hit()
        }
        #else
        app.buttons["kanbanBoard-close"].hit()
        #endif
        waitFor(entry, timeout: 20, "leaving Kanban lands on the home list")
        XCTAssertFalse(any(app, "kanbanBoard").exists, "the board is gone")
    }
}
