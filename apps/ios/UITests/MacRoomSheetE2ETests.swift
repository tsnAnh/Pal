#if os(macOS)
import XCTest

@MainActor
final class MacRoomSheetE2ETests: E2ETestCase {
    func test1CreateSheetShowsTheInsetListAndEnablesCreate() throws {
        let app = launch()
        signInIfNeeded(app)
        let open = app.buttons["createRoomButton"]
        waitFor(open, timeout: 90, "New Group Chat needs the hosted room driver and two seatable bots")
        open.hit()
        waitFor(app.descendants(matching: .any)["createRoomSheet"], timeout: 15, "create sheet")
        let create = app.buttons["roomCreateButton"]
        waitFor(create, timeout: 10, "Create")
        XCTAssertFalse(create.isEnabled)
        shot(app, "mac-room-create-empty")
        let field = app.textFields["roomNameField"]
        field.hit()
        field.typeText("Planning Crew")
        let first = app.buttons["roomPick-bot-alpha"]
        let second = app.buttons["roomPick-bot-beta"]
        waitFor(first, timeout: 10, "first bot row")
        first.hit()
        second.hit()
        XCTAssertTrue(create.isEnabled)
        shot(app, "mac-room-create-selected")
    }
}
#endif
