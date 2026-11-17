import XCTest

@MainActor
final class KanbanE2ETests: E2ETestCase {
    private let title = "release notes"

    private func any(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func card(_ app: XCUIApplication, in column: String) -> XCUIElement {
        any(app, "kanbanColumn-\(column)").buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
    }

    private func openSeededBoard(_ app: XCUIApplication) {
        waitFor(any(app, "kanbanBoard"), timeout: 20, "Kanban opens straight into a board")
        XCTAssertFalse(any(app, "kanbanBoards").exists, "no boards list in the flow")
        let picker = any(app, "kanbanBoardPicker")
        waitFor(picker, timeout: 20, "the board dropdown shows even before a second board loads")
        XCTAssertFalse((picker.value as? String ?? "").isEmpty, "the dropdown names the open board")
        picker.hit()
        let ops = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label BEGINSWITH %@", "kanbanBoard-ops", "Ops")).firstMatch
        waitFor(ops, timeout: 10, "the seeded board in the board picker")
        ops.hit()
    }

    private func show(_ app: XCUIApplication, column: String) {
        let chip = app.buttons["kanbanColumns-\(column)"]
        if chip.exists { chip.hit() }
    }

    func testBoardFollowsALiveEventAndOpensTheCard() throws {
        try control("kanban-seed")
        let app = launch()
        signInIfNeeded(app)

        let entry = app.buttons["kanbanButton"]
        waitFor(entry, timeout: 20, "work boards button")
        entry.hit()
        openSeededBoard(app)

        waitFor(any(app, "kanbanBoard"), timeout: 20, "board page")
        for column in ["backlog", "ready", "inProgress", "done"] {
            waitFor(any(app, "kanbanColumn-\(column)"), timeout: 20, "\(column) column")
        }
        show(app, column: "ready")
        waitFor(card(app, in: "ready"), timeout: 20, "the card starts in Ready")

        try control("kanban-advance")

        show(app, column: "done")
        waitFor(card(app, in: "done"), timeout: 15, "the completed card shows in Done within the follow interval")
        XCTAssertFalse(card(app, in: "ready").exists, "the card left Ready")

        card(app, in: "done").hit()
        waitFor(any(app, "kanbanBody"), timeout: 20, "card detail description")
        XCTAssertTrue(app.staticTexts["thank the testers"].waitForExistence(timeout: 10), "list items render as text")
        waitFor(any(app, "kanbanMetadata"), timeout: 10, "machine lines are collapsed into one metadata group")
        XCTAssertFalse(app.staticTexts["Key: PAL-1"].exists, "machine lines are not shown while collapsed")
        screenShot("kanban-card-detail")
    }

    func testBoardShowsTitleAssigneeAvatarAndPullRequestChip() throws {
        try control("kanban-seed")
        let app = launch()
        signInIfNeeded(app)

        let entry = app.buttons["kanbanButton"]
        waitFor(entry, timeout: 20, "work boards button")
        XCTAssertEqual(entry.label, "Pal Kanban", "the entry is labelled Pal Kanban")
        entry.hit()
        openSeededBoard(app)

        #if os(macOS)
        let heading = any(app, "kanbanBoard-title")
        waitFor(heading, timeout: 20, "board header")
        XCTAssertEqual(heading.label, "Pal Kanban", "the board header reads Pal Kanban")
        #else
        waitFor(app.navigationBars["Pal Kanban"], timeout: 20, "the board header reads Pal Kanban")
        #endif
        XCTAssertEqual(any(app, "kanbanBoardPicker").value as? String, "Ops", "the dropdown switched to the chosen board")
        show(app, column: "done")
        let merged = any(app, "kanbanColumn-done").buttons
            .matching(NSPredicate(format: "label CONTAINS %@", "Publish the docs")).firstMatch
        waitFor(merged, timeout: 20, "the merged card in Done")
        XCTAssertTrue(merged.label.contains("bot-alpha"), "the card names its assignee")
        XCTAssertTrue(merged.label.contains("Pull request #42, Merged"), "the card carries the merged PR chip")
        screenShot("kanban-glass-board")

        merged.hit()
        waitFor(any(app, "kanbanAssignee-bot-alpha"), timeout: 20, "the detail shows the avatar assignee")
        waitFor(any(app, "kanbanPullRequest"), timeout: 10, "the detail shows the PR chip with its state")
        screenShot("kanban-glass-card-detail")
    }

    #if os(iOS)
    private func systemBack(_ app: XCUIApplication) -> XCUIElement {
        app.navigationBars.buttons.element(boundBy: 0)
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
        assertOneWayOut(app, close: true, "board")
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

        app.buttons["kanbanBoard-close"].hit()
        waitFor(entry, timeout: 20, "close dismisses the Kanban surface")
        XCTAssertFalse(any(app, "kanbanBoard").exists, "the board is gone")
    }

    #if os(macOS)
    func testMacBoardChromeClearsTheTitleBar() throws {
        try control("kanban-seed")
        let app = launch()
        signInIfNeeded(app)
        let entry = app.buttons["kanbanButton"]
        waitFor(entry, timeout: 20, "work boards button")
        entry.hit()
        openSeededBoard(app)
        waitFor(any(app, "kanbanBoard-title"), timeout: 20, "board header")

        let window = app.windows.firstMatch.frame
        let titleBar = CGRect(x: window.minX, y: window.minY, width: window.width, height: 55)
        let trafficLights = CGRect(x: window.minX, y: window.minY, width: 78, height: 35)
        XCTAssertTrue(app.toolbars.buttons.count == 0, "Kanban puts nothing in the window toolbar")
        for identifier in ["kanbanBoard-close", "kanbanBoard-title", "kanbanBoardPicker", "kanbanFilterState"] {
            let element = any(app, identifier)
            XCTAssertTrue(element.exists, "\(identifier) is on screen")
            XCTAssertFalse(element.frame.intersects(titleBar), "\(identifier) sits below the title bar")
            XCTAssertFalse(element.frame.intersects(trafficLights), "\(identifier) is clear of the traffic lights")
        }
        XCTAssertFalse(any(app, "kanbanTitle").exists, "the filter bar no longer repeats the title and board name")

        let close = any(app, "kanbanBoard-close").frame
        let title = any(app, "kanbanBoard-title").frame
        let picker = any(app, "kanbanBoardPicker").frame
        for (name, frame) in [("title", title), ("dropdown", picker)] {
            XCTAssertEqual(frame.midY, close.midY, accuracy: 2, "the \(name) shares the close button's row")
        }
        XCTAssertEqual(picker.height, close.height, accuracy: 2, "the dropdown is as tall as the close button")
        XCTAssertLessThan(close.maxX, title.minX, "the title follows the close button")
        XCTAssertLessThan(title.maxX, picker.minX, "the dropdown sits right of the title")
        XCTAssertLessThanOrEqual(close.minY - titleBar.maxY, 2, "no empty band above the header row")
        let filter = any(app, "kanbanFilterState").frame
        XCTAssertGreaterThanOrEqual(filter.minY, close.maxY, "the filter bar starts below the header row")
        screenShot("kanban-mac-board-chrome")
    }
    #endif
}
