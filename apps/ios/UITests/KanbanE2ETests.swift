import XCTest

@MainActor
final class KanbanE2ETests: E2ETestCase {
    private let title = "Write release notes"

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
}
