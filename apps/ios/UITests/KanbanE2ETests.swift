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
        let boardRow = any(app, "kanbanBoard-ops")
        waitFor(boardRow, timeout: 20, "the seeded board in the boards list")
        boardRow.hit()

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
        let boardRow = any(app, "kanbanBoard-ops")
        waitFor(boardRow, timeout: 20, "the seeded board in the boards list")
        boardRow.hit()

        let heading = any(app, "kanbanTitle")
        waitFor(heading, timeout: 20, "board header")
        XCTAssertEqual(heading.label, "Pal Kanban", "the board header reads Pal Kanban")
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

    private func systemBack(_ app: XCUIApplication) -> XCUIElement {
        #if os(macOS)
        app.toolbars.buttons.element(boundBy: 0)
        #else
        app.navigationBars.buttons.element(boundBy: 0)
        #endif
    }

    private func assertOneWayOut(_ app: XCUIApplication, close: Bool, _ screen: String) {
        for duplicate in ["kanbanBoards-back", "kanbanBoard-back", "kanbanCard-back", "kanbanBoard-close", "kanbanCard-close", "kanban-close"] {
            XCTAssertFalse(any(app, duplicate).exists, "\(screen) has no \(duplicate)")
        }
        XCTAssertEqual(app.buttons.matching(identifier: "kanbanBoards-close").count, close ? 1 : 0, "\(screen) close count")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == 'Close'")).count, close ? 1 : 0, "\(screen) has \(close ? "one" : "no") close")
    }

    func testEachScreenHasOneSystemWayOut() throws {
        try control("kanban-seed")
        let app = launch()
        signInIfNeeded(app)

        let entry = app.buttons["kanbanButton"]
        waitFor(entry, timeout: 20, "work boards button")
        entry.hit()
        let boardRow = any(app, "kanbanBoard-ops")
        waitFor(boardRow, timeout: 20, "the seeded board in the boards list")
        assertOneWayOut(app, close: true, "boards list")

        boardRow.hit()
        waitFor(any(app, "kanbanBoard"), timeout: 20, "board page")
        assertOneWayOut(app, close: false, "board")
        show(app, column: "ready")
        let row = card(app, in: "ready")
        waitFor(row, timeout: 20, "the card in Ready")

        row.hit()
        waitFor(any(app, "kanbanBody"), timeout: 20, "card detail")
        assertOneWayOut(app, close: false, "card detail")

        systemBack(app).hit()
        waitFor(any(app, "kanbanBoard"), timeout: 20, "back from the card lands on the board")
        XCTAssertFalse(any(app, "kanbanBody").exists, "the card detail is gone")

        systemBack(app).hit()
        waitFor(boardRow, timeout: 20, "back from the board lands on the boards list")
        XCTAssertFalse(any(app, "kanbanBoard").exists, "the board is gone")

        app.buttons["kanbanBoards-close"].hit()
        waitFor(entry, timeout: 20, "close dismisses the Kanban surface")
        XCTAssertFalse(any(app, "kanbanBoards").exists, "the boards list is gone")
    }
}
