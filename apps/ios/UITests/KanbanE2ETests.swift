import XCTest

@MainActor
final class KanbanE2ETests: KanbanE2ETestCase {
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
        XCTAssertFalse(any(app, "kanbanDetails-toggle").exists, "the card has no Details control")
        XCTAssertFalse(app.staticTexts["Key: PAL-1"].exists, "machine lines are never shown")
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

    #if os(macOS)
    func testMacBoardChromeClearsTheTitleBar() throws {
        try control("kanban-seed")
        let app = launch()
        signInIfNeeded(app)
        let entry = app.buttons["kanbanButton"]
        waitFor(entry, timeout: 20, "work boards button")
        let search = any(app, "rosterSearchField").frame
        entry.hit()
        openSeededBoard(app)
        waitFor(any(app, "kanbanBoard-title"), timeout: 20, "board header")

        let window = app.windows.firstMatch.frame
        let trafficLights = CGRect(x: window.minX, y: window.minY, width: 78, height: 30)
        XCTAssertTrue(app.toolbars.buttons.count == 0, "Kanban puts nothing in the window toolbar")
        for identifier in ["kanbanBoard-close", "kanbanBoard-title", "kanbanBoardPicker", "kanbanFilterState"] {
            let element = any(app, identifier)
            XCTAssertTrue(element.exists, "\(identifier) is on screen")
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
        XCTAssertEqual(close.minY - window.minY, 30.5, accuracy: 2, "the header row sits just below the traffic lights, with no empty band")
        XCTAssertEqual(close.width, search.width, accuracy: 0.5, "the close button is the same size as the search button")
        XCTAssertEqual(close.height, search.height, accuracy: 0.5, "the close button is the same height as the search button")
        let filter = any(app, "kanbanFilterState").frame
        XCTAssertGreaterThanOrEqual(filter.minY, close.maxY, "the filter bar starts below the header row")
        screenShot("kanban-mac-board-chrome")
    }

    func testEscapeClosesTopmostFirstThenKanban() throws {
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

        let search = any(app, "kanbanSearch")
        search.hit()
        search.typeText("zzz")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertEqual(search.value as? String ?? "", "", "Escape clears the search text first")
        XCTAssertTrue(any(app, "kanbanBoard").exists, "Kanban stays open while the search had text")

        row.hit()
        waitFor(any(app, "kanbanBody"), timeout: 20, "card detail")
        app.typeKey(.escape, modifierFlags: [])
        waitFor(any(app, "kanbanBoard"), timeout: 20, "Escape closes the card first")
        XCTAssertFalse(any(app, "kanbanBody").exists, "the card detail is gone")

        app.typeKey(.escape, modifierFlags: [])
        waitFor(entry, timeout: 20, "a second Escape closes Kanban")
        XCTAssertFalse(any(app, "kanbanBoard").exists, "the board is gone")

        entry.hit()
        openSeededBoard(app)
        app.typeKey(.escape, modifierFlags: [])
        waitFor(entry, timeout: 20, "Escape closes Kanban from the board")
    }
    #endif
}
