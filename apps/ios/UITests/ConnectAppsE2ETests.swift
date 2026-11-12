import EventKit
import PalDesign
import XCTest

@MainActor
class ConnectAppsTestCase: E2ETestCase {
    func launchConnectApps() -> XCUIApplication {
        let app = launch(extraArguments: [
            "-hermes-open-connect-apps",
            "-\(AppearanceStore.defaultsKey)", AppearanceMode.dark.rawValue,
        ])
        if !sheet(app).waitForExistence(timeout: 25) { signInIfNeeded(app) }
        waitFor(sheet(app), timeout: 30, "connect apps sheet")
        return app
    }

    func sheet(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["connectApps"]
    }

    func chip(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.buttons["connectAppsChips-\(id)"]
    }

    func waitLabel(_ element: XCUIElement, contains text: String, timeout: TimeInterval = 30, file: StaticString = #filePath, line: UInt = #line) {
        let match = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", text), object: element)
        XCTAssertEqual(XCTWaiter().wait(for: [match], timeout: timeout), .completed, "\(element.identifier) never read '\(text)'\n" + XCUIApplication().debugDescription, file: file, line: line)
    }

    func waitForCatalog(_ app: XCUIApplication, timeout: TimeInterval = 40) {
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "connectApp-"))
        waitFor(rows.firstMatch, timeout: timeout, "catalog loaded")
    }

    func closeSheet(_ app: XCUIApplication) {
        app.buttons["connectApps-close"].tap()
        waitGone(sheet(app), timeout: 10, "sheet closes")
    }

    func openDefaultBotChat(_ app: XCUIApplication) {
        openBot(app, "default")
    }

    func tapChip(_ app: XCUIApplication, _ id: String) {
        let target = chip(app, id)
        waitFor(target, timeout: 10, "\(id) chip")
        let row = app.descendants(matching: .any)["connectAppsChips"]
        let screen = app.windows.firstMatch.frame
        let leading = row.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
        let trailing = row.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
        for _ in 0..<10 where !screen.contains(target.frame) {
            if target.frame.minX < screen.minX {
                leading.press(forDuration: 0.1, thenDragTo: trailing)
            } else {
                trailing.press(forDuration: 0.1, thenDragTo: leading)
            }
        }
        target.tap()
    }

    func assistantReply(_ app: XCUIApplication, containing text: String, timeout: TimeInterval = 90) {
        waitFor(bubbles(app, "assistantBubble", containing: text).firstMatch, timeout: timeout, "assistant reply containing '\(text)'")
    }
}

@MainActor
final class ConnectAppsE2ETests: ConnectAppsTestCase {
    func test1ChipsSearchAndNoDeviceSwitches() throws {
        let app = launchConnectApps()
        waitFor(chip(app, "all"), timeout: 30, "All chip")
        waitForCatalog(app)
        XCTAssertTrue(app.staticTexts["Connect apps"].exists)
        XCTAssertTrue(app.buttons["connectedCountButton"].label.hasSuffix("connected"), app.buttons["connectedCountButton"].label)
        XCTAssertFalse(chip(app, "iphone").exists, "no device chip")
        XCTAssertFalse(app.descendants(matching: .any)["connectAppsSection-iphone"].exists, "no device section")
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "deviceConnector-")).firstMatch.exists, "no device rows")
        shot(app, "connect-apps-all")

        let category = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND NOT identifier ENDSWITH %@", "connectAppsChips-", "-all")).firstMatch
        waitFor(category, timeout: 30, "a catalog category chip")
        let categoryID = category.identifier.replacingOccurrences(of: "connectAppsChips-", with: "")
        category.tap()
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@ AND NOT identifier ENDSWITH %@", "connectApp-", "-action"))
        waitFor(rows.firstMatch, timeout: 20, "rows in \(categoryID)")
        XCTAssertTrue(app.descendants(matching: .any)["connectAppsSectionTitle"].exists)
        shot(app, "connect-apps-category")

        let search = app.descendants(matching: .any)["connectAppsSearch"]
        search.tap()
        search.typeText("Calendar")
        XCTAssertFalse(app.descendants(matching: .any)["deviceConnector-calendar"].exists, "search finds no device connector")
    }

    func test1bCapabilitiesListShowsEachCapabilityRow() throws {
        let app = launchConnectApps()
        let list = app.descendants(matching: .any)["capabilitiesList"]
        for _ in 0..<12 where !list.exists { app.swipeUp() }
        waitFor(list, timeout: 30, "capabilities list")
        for id in ["web", "deep_search", "youtube", "maps", "browser"] {
            let row = app.descendants(matching: .any)["capabilityRow-\(id)"]
            for _ in 0..<4 where !row.exists { app.swipeUp() }
            waitFor(row, timeout: 10, "capability row \(id)")
        }
        shot(app, "connect-apps-capabilities")
    }

    func test2TheBotReadsTodaysEventsWithNoSwitch() async throws {
        let store = EKEventStore()
        let granted = try await store.requestFullAccessToEvents()
        try XCTSkipUnless(granted, "run apps/ios/Scripts/device-tools-fixture grant first")
        let event = EKEvent(eventStore: store)
        event.title = "Hermes sync review"
        event.startDate = Date().addingTimeInterval(3600)
        event.endDate = Date().addingTimeInterval(5400)
        event.calendar = store.defaultCalendarForNewEvents
        try store.save(event, span: .thisEvent)
        let identifier = try XCTUnwrap(event.eventIdentifier)
        addTeardownBlock {
            if let stored = store.event(withIdentifier: identifier) { try? store.remove(stored, span: .thisEvent) }
        }

        let app = launchConnectApps()
        closeSheet(app)
        openDefaultBotChat(app)
        send(app, "IPHONE CALENDAR what is on today")
        assistantReply(app, containing: "Hermes sync review")
        shot(app, "chat-calendar-reply")
    }
}
