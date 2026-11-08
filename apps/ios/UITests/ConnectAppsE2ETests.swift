import EventKit
import HermesDesign
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

    func deviceAction(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.buttons["deviceConnector-\(id)-action"]
    }

    func openIphoneSection(_ app: XCUIApplication) {
        waitFor(chip(app, "iphone"), timeout: 30, "iPhone chip")
        chip(app, "iphone").tap()
        waitFor(app.descendants(matching: .any)["connectAppsIphoneCaption"], timeout: 10, "iPhone caption")
    }

    func waitLabel(_ element: XCUIElement, contains text: String, timeout: TimeInterval = 30, file: StaticString = #filePath, line: UInt = #line) {
        let match = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", text), object: element)
        XCTAssertEqual(XCTWaiter().wait(for: [match], timeout: timeout), .completed, "\(element.identifier) never read '\(text)'\n" + XCUIApplication().debugDescription, file: file, line: line)
    }

    func enable(_ app: XCUIApplication, _ id: String, title: String) {
        openIphoneSection(app)
        let action = deviceAction(app, id)
        waitFor(action, timeout: 20, "\(id) action")
        if action.label.hasPrefix("Connected") { return }
        action.tap()
        waitLabel(deviceAction(app, id), contains: "Connected \(title)")
    }

    func closeSheet(_ app: XCUIApplication) {
        app.buttons["connectApps-close"].tap()
        waitGone(sheet(app), timeout: 10, "sheet closes")
    }

    func openHeroChat(_ app: XCUIApplication) {
        let hero = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "botRow-")).firstMatch
        waitFor(hero, timeout: 30, "hero row")
        hero.tap()
        waitFor(app.descendants(matching: .any)["composerField"], timeout: 20, "composer")
    }

    func assistantReply(_ app: XCUIApplication, containing text: String, timeout: TimeInterval = 90) {
        waitFor(bubbles(app, "assistantBubble", containing: text).firstMatch, timeout: timeout, "assistant reply containing '\(text)'")
    }
}

@MainActor
final class ConnectAppsE2ETests: ConnectAppsTestCase {
    func test1ChipsSearchAndThisIphoneSection() throws {
        let app = launchConnectApps()
        waitFor(chip(app, "all"), timeout: 30, "All chip")
        waitFor(app.descendants(matching: .any)["connectAppsSection-iphone"], timeout: 30, "This iPhone section in All")
        XCTAssertTrue(app.staticTexts["Connect apps"].exists)
        XCTAssertTrue(app.buttons["connectedCountButton"].label.hasSuffix("connected"), app.buttons["connectedCountButton"].label)

        openIphoneSection(app)
        for id in ["calendar", "home", "reminders", "contacts", "location", "alarms"] {
            waitFor(deviceAction(app, id), timeout: 10, "device row \(id)")
        }
        XCTAssertTrue(app.staticTexts["See your day and add events"].exists)
        shot(app, "connect-apps-iphone")

        let category = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND NOT identifier ENDSWITH %@ AND NOT identifier ENDSWITH %@", "connectAppsChips-", "-all", "-iphone")).firstMatch
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
        waitFor(deviceAction(app, "calendar"), timeout: 10, "search finds the Calendar connector")
        XCTAssertFalse(deviceAction(app, "home").exists, "search narrows the rows")
    }

    func test2EnablingCalendarLetsTheBotReadTodaysEvents() async throws {
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
        enable(app, "calendar", title: "Calendar")
        shot(app, "connect-apps-calendar-connected")
        closeSheet(app)
        openHeroChat(app)
        send(app, "IPHONE CALENDAR what is on today")
        assistantReply(app, containing: "Hermes sync review")
        shot(app, "chat-calendar-reply")
    }

    func test3ATurnedOffConnectorIsRefusedAndAnEnabledOneStillWorks() throws {
        let app = launchConnectApps()
        enable(app, "calendar", title: "Calendar")
        enable(app, "reminders", title: "Reminders")
        deviceAction(app, "reminders").tap()
        let turnOff = app.alerts.buttons["Turn off"]
        waitFor(turnOff, timeout: 10, "turn off confirmation")
        turnOff.tap()
        waitLabel(deviceAction(app, "reminders"), contains: "Allow Reminders")
        shot(app, "connect-apps-reminders-off")
        closeSheet(app)
        openHeroChat(app)
        send(app, "IPHONE REMINDERS list them")
        assistantReply(app, containing: "iPhone refused: connector_off")
        send(app, "IPHONE CALENDAR what is on today")
        assistantReply(app, containing: "iPhone data:")
        shot(app, "chat-reminders-refused")
    }

    func test4TheFirstUseOfAConnectorAsksAndThenRemembers() throws {
        let app = launchConnectApps()
        enable(app, "calendar", title: "Calendar")
        openIphoneSection(app)
        waitLabel(deviceAction(app, "contacts"), contains: "Allow Contacts")
        closeSheet(app)
        openHeroChat(app)
        send(app, "IPHONE CONTACTS Quokka")
        let allow = app.alerts.buttons["Allow"]
        waitFor(allow, timeout: 60, "consent prompt")
        XCTAssertTrue(app.alerts.firstMatch.label.contains("Contacts"), app.alerts.firstMatch.label)
        shot(app, "chat-contacts-consent")
        allow.tap()
        assistantReply(app, containing: "iPhone data:")
        app.terminate()

        let relaunched = launchConnectApps()
        openIphoneSection(relaunched)
        waitLabel(deviceAction(relaunched, "contacts"), contains: "Connected Contacts")
        shot(relaunched, "connect-apps-contacts-remembered")
    }
}
