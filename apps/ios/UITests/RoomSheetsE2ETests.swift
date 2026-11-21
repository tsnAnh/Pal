import XCTest

@MainActor
final class RoomSheetsE2ETests: E2ETestCase {
    private let firstBot = "roomPick-bot-alpha"
    private let secondBot = "roomPick-bot-beta"

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func openCreateSheet() -> XCUIApplication {
        let app = launch()
        signInIfNeeded(app)
        let open = app.buttons["createRoomButton"]
        waitFor(open, timeout: 90, "New Group Chat needs the hosted room driver and two seatable bots")
        open.tap()
        waitFor(element(app, "createRoomSheet"), timeout: 15, "create sheet")
        return app
    }

    private func nameTheRoom(_ app: XCUIApplication, _ name: String) {
        let field = app.textFields["roomNameField"]
        waitFor(field, timeout: 10, "name field")
        field.tap()
        waitFor(app.keyboards.firstMatch, timeout: 10, "keyboard for the name field")
        field.typeText(name + "\n")
    }

    func test1CreateSheetIsAListAndCreateNeedsAnameAndTwoBots() throws {
        let app = openCreateSheet()
        let create = app.buttons["roomCreateButton"]
        waitFor(create, timeout: 10, "Create")
        XCTAssertFalse(create.isEnabled, "Create stays disabled until the group is named and has two bots")
        waitFor(element(app, "createRoomBotsCaption"), timeout: 10, "Bots caption")
        XCTAssertTrue(app.collectionViews.firstMatch.exists || app.tables.firstMatch.exists, "the sheet body is a native list")
        shot(app, "room-create-empty")

        nameTheRoom(app, "Planning Crew")
        let first = app.buttons[firstBot]
        let second = app.buttons[secondBot]
        waitFor(first, timeout: 10, "first bot row")
        waitFor(second, timeout: 10, "second bot row")
        XCTAssertFalse(first.isSelected)
        first.tap()
        XCTAssertTrue(first.isSelected, "a tapped row reports the selected trait")
        XCTAssertFalse(create.isEnabled, "one bot is not enough")
        second.tap()
        XCTAssertTrue(second.isSelected)
        XCTAssertTrue(create.isEnabled, "a name and two bots enable Create")
        shot(app, "room-create-selected")

        first.tap()
        XCTAssertFalse(first.isSelected, "tapping again clears the selection")
        XCTAssertFalse(create.isEnabled)
    }

    func test2CreateFailureShowsAsTheListFooter() throws {
        let app = openCreateSheet()
        nameTheRoom(app, String(repeating: "x", count: 121))
        app.buttons[firstBot].tap()
        app.buttons[secondBot].tap()
        let create = app.buttons["roomCreateButton"]
        XCTAssertTrue(create.isEnabled)
        create.tap()
        waitFor(element(app, "createRoomFailure"), timeout: 15, "failure footer")
        shot(app, "room-create-failure")
    }

    func test3CreatedRoomOpensItsDetailsWithSave() throws {
        let app = openCreateSheet()
        nameTheRoom(app, "Details Crew")
        app.buttons[firstBot].tap()
        app.buttons[secondBot].tap()
        app.buttons["roomCreateButton"].tap()
        waitFor(element(app, "roomScreen"), timeout: 60, "the new group chat opens")
        let title = app.buttons["roomTitle"]
        waitFor(title, timeout: 15, "title button")
        title.tap()
        waitFor(element(app, "roomDetailsSheet"), timeout: 15, "details sheet")
        let save = app.buttons["roomRenameSave"]
        XCTAssertFalse(save.isEnabled, "Save stays disabled until the name changes")
        let field = app.textFields["roomRenameField"]
        field.tap()
        field.typeText(" Two")
        XCTAssertTrue(save.isEnabled)
        shot(app, "room-details-save")
    }

    func test4SystemButtonsTakeInkNotBlue() throws {
        let app = launch(resetCredentials: true)
        let options = app.buttons["otherOptionsButton"]
        waitFor(options, timeout: 30, "other options on the landing")
        options.tap()
        waitFor(app.buttons["signInButton"], timeout: 15, "sign in button in the options sheet")
        shot(app, "system-buttons-ink")
    }
}
