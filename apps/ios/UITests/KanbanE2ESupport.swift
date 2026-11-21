import XCTest
#if os(iOS)
import UIKit
#endif

@MainActor
class KanbanE2ETestCase: E2ETestCase {
    let title = "release notes"

    var pushesKanban: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }

    #if os(iOS)
    func systemBack(_ app: XCUIApplication) -> XCUIElement {
        app.navigationBars.buttons.element(boundBy: 0)
    }
    #endif

    func any(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    func card(_ app: XCUIApplication, in column: String) -> XCUIElement {
        any(app, "kanbanColumn-\(column)").buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
    }

    func openSeededBoard(_ app: XCUIApplication) {
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

    func show(_ app: XCUIApplication, column: String) {
        let chip = app.buttons["kanbanColumns-\(column)"]
        guard chip.exists else { return }
        let bar = any(app, "kanbanColumns")
        let screen = app.windows.firstMatch.frame
        for _ in 0..<3 where chip.frame.maxX > screen.maxX - 8 { bar.swipeLeft() }
        chip.hit()
    }
}
