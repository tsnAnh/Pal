import EventKit
import PalDesign
import XCTest

@MainActor
class ConnectAppsTestCase: E2ETestCase {
    func launchConnectApps(extraArguments: [String] = []) -> XCUIApplication {
        let app = launch(extraArguments: [
            "-hermes-open-connect-apps",
            "-hermes-record-external-links",
            "-\(AppearanceStore.defaultsKey)", AppearanceMode.dark.rawValue,
        ] + extraArguments)
        if !sheet(app).waitForExistence(timeout: 25) { signInIfNeeded(app) }
        waitFor(sheet(app), timeout: 30, "connect apps sheet")
        return app
    }

    func sheet(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["connectApps"]
    }

    func waitLabel(_ element: XCUIElement, contains text: String, timeout: TimeInterval = 30, file: StaticString = #filePath, line: UInt = #line) {
        let match = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", text), object: element)
        let result = XCTWaiter().wait(for: [match], timeout: timeout)
        XCTAssertEqual(result, .completed, "\(element.identifier) never read '\(text)'\n" + XCUIApplication().debugDescription, file: file, line: line)
    }

    func waitLabel(_ element: XCUIElement, equals text: String, timeout: TimeInterval = 30, file: StaticString = #filePath, line: UInt = #line) {
        let match = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", text), object: element)
        let result = XCTWaiter().wait(for: [match], timeout: timeout)
        XCTAssertEqual(result, .completed, "\(element.identifier) never read '\(text)'\n" + XCUIApplication().debugDescription, file: file, line: line)
    }

    func actionButtons(_ app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@", "connectApp-", "-action"))
    }

    func waitForCatalog(_ app: XCUIApplication, timeout: TimeInterval = 40) {
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "connectApp-"))
        waitFor(rows.firstMatch, timeout: timeout, "catalog loaded")
    }

    func waitUntil(_ timeout: TimeInterval, _ message: String, file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            Thread.sleep(forTimeInterval: 0.3)
        }
        XCTFail(message, file: file, line: line)
    }

    func closeSheet(_ app: XCUIApplication) {
        app.buttons["connectApps-close"].tap()
        waitGone(sheet(app), timeout: 10, "sheet closes")
    }

    func openDefaultBotChat(_ app: XCUIApplication) {
        openBot(app, "default")
    }

    func assistantReply(_ app: XCUIApplication, containing text: String, timeout: TimeInterval = 90) {
        waitFor(bubbles(app, "assistantBubble", containing: text).firstMatch, timeout: timeout, "assistant reply containing '\(text)'")
    }
    func search(_ app: XCUIApplication, _ text: String) {
        let field = app.descendants(matching: .any)["connectAppsSearch"]
        for _ in 0..<20 where !field.isHittable { app.swipeDown() }
        field.hit()
        field.typeText(text)
    }

    func action(_ app: XCUIApplication, _ slug: String) -> XCUIElement {
        app.buttons["connectApp-connector:\(slug)-action"]
    }

}

@MainActor
final class ConnectAppsE2ETests: ConnectAppsTestCase {
    func test1SectionsSearchAndNoDeviceSwitches() throws {
        let app = launchConnectApps()
        waitForCatalog(app)
        XCTAssertTrue(app.staticTexts["Connect Apps"].exists)
        XCTAssertFalse(app.buttons["connectedCountButton"].exists, "the Connected section replaces the count button")
        XCTAssertFalse(app.buttons["connectAppsChips-all"].exists, "sections replace the filter chips")
        XCTAssertFalse(app.descendants(matching: .any)["connectAppsSection-iphone"].exists, "no device section")
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "deviceConnector-")).firstMatch.exists, "no device rows")
        let headerFormat = "identifier BEGINSWITH %@ AND NOT identifier BEGINSWITH %@"
        let headers = app.descendants(matching: .any).matching(NSPredicate(format: headerFormat, "connectAppsSection-", "connectAppsSection-device"))
        waitFor(headers.firstMatch, timeout: 30, "a section header")
        shot(app, "connect-apps-all")

        let search = app.descendants(matching: .any)["connectAppsSearch"]
        search.tap()
        search.typeText("Calendar")
        XCTAssertFalse(app.descendants(matching: .any)["deviceConnector-calendar"].exists, "search finds no device connector")
    }

    func test1dEveryRowShowsOneStateWithOneGlassAction() throws {
        let app = launchConnectApps()
        waitForCatalog(app)
        let allowed: Set<String> = ["Connect", "Set up", "Connected", "Reconnect"]
        let buttons = actionButtons(app)
        XCTAssertGreaterThan(buttons.count, 0, "rows offer actions")
        for index in 0..<min(buttons.count, 12) {
            let label = buttons.element(boundBy: index).label
            XCTAssertTrue(allowed.contains(label), "unexpected row action '\(label)'")
        }
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label == %@", "Try again")).firstMatch.exists, "no bare Try again in the list")
        shot(app, "connect-apps-row-states")
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

    func test1cAddCustomConnectorSitsAfterTheLastSection() throws {
        let app = launchConnectApps()
        waitForCatalog(app)
        let add = app.buttons["addCustomConnectorButton"]
        XCTAssertFalse(add.exists && add.isHittable, "add button is not pinned on screen above a long list")
        for _ in 0..<20 where !(add.exists && add.isHittable) { app.swipeUp() }
        XCTAssertTrue(add.isHittable, "scrolling to the end reveals the add button")
        shot(app, "connect-apps-add-at-end")

        let search = app.descendants(matching: .any)["connectAppsSearch"]
        for _ in 0..<20 where !search.isHittable { app.swipeDown() }
        search.tap()
        search.typeText("zzzz no such app")
        let noMatches = app.descendants(matching: .any)["connectAppsNoMatches"]
        waitFor(noMatches, timeout: 10, "no matches")
        waitFor(add, timeout: 5, "add button on a short list")
        XCTAssertTrue(add.isHittable, "add button reachable on a short list with the keyboard open")
        XCTAssertLessThan(add.frame.minY - noMatches.frame.maxY, 120, "add button sits right after the last section")
        let keyboard = app.keyboards.firstMatch
        if keyboard.exists { XCTAssertLessThanOrEqual(add.frame.maxY, keyboard.frame.minY, "add button not under the keyboard") }

        app.buttons["connectAppsSearch-clear"].tap()
        search.tap()
        for _ in 0..<20 where !(add.exists && add.isHittable) { app.swipeUp() }
        XCTAssertTrue(add.isHittable, "long list scrolls to the add button with search focused")
        if keyboard.exists { XCTAssertLessThanOrEqual(add.frame.maxY, keyboard.frame.minY, "add button not under the keyboard") }
        add.tap()
        waitFor(app.buttons["customConnectorBackButton"], timeout: 10, "custom connector form opens")
    }

    func test3AnAppWithNoSignInConnectsDirectlyAndDisconnects() throws {
        let app = launchConnectApps()
        waitForCatalog(app)
        search(app, "Deepwiki")
        let connect = action(app, "deepwiki")
        waitFor(connect, timeout: 30, "Deepwiki action")
        XCTAssertEqual(connect.label, "Connect")
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "Nous")).firstMatch.exists, "no Nous Portal sign-in copy")
        connect.hit()
        waitLabel(connect, equals: "Connected")
        shot(app, "connect-apps-direct-connected")
        connect.hit()
        let disconnect = app.buttons["Disconnect"]
        waitFor(disconnect, timeout: 10, "disconnect confirmation")
        disconnect.hit()
        waitLabel(connect, equals: "Connect")
    }

    func test4TheSlackRowOpensTheBotPickerAndTheWizardForTheChosenBot() throws {
        let app = launchConnectApps(extraArguments: ["-hermes-test-chat-install", "-hermes-test-chat-install-reset"])
        waitForCatalog(app)
        search(app, "Slack")
        let row = app.descendants(matching: .any)["connectApp-connector:slack"]
        waitFor(row, timeout: 30, "Slack row")
        waitFor(app.staticTexts["Per bot · one-time setup"], timeout: 30, "Slack row status")
        XCTAssertFalse(app.staticTexts["Needs setup on your Pal before it can connect."].exists, "no Client ID sheet copy")
        let open = action(app, "slack")
        waitFor(open, timeout: 10, "Slack action")
        XCTAssertEqual(open.label, "Set up")
        open.hit()
        waitFor(app.descendants(matching: .any)["slackBotPicker"], timeout: 20, "bot picker")
        let bot = app.descendants(matching: .any)["slackBot-default"]
        waitFor(bot, timeout: 30, "default bot in the picker")
        XCTAssertTrue(app.staticTexts["Not installed"].exists, "the bot reads not installed")
        bot.hit()
        waitFor(app.descendants(matching: .any)["stepFlow"], timeout: 30, "Slack setup for the chosen bot")
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "Nous")).firstMatch.exists, "no Nous Portal sign-in copy")
    }

    func test5AnOAuthAppStartsSignInThroughTheSystemBrowserAndLeavesNothingBehindWhenCancelled() throws {
        #if os(macOS)
        throw XCTSkip("Mac signs in through ASWebAuthenticationSession, which a UI test cannot drive")
        #else
        let app = launchConnectApps()
        waitForCatalog(app)
        search(app, "Notion")
        let connect = action(app, "notion")
        waitFor(connect, timeout: 30, "Notion action")
        XCTAssertEqual(connect.label, "Connect")
        connect.hit()
        let paste = app.descendants(matching: .any)["otherConnectorPaste"]
        let notice = app.alerts.firstMatch
        waitUntil(60, "paste sign-in or a plain failure") { paste.exists || notice.exists }
        if paste.exists {
            let opened = app.descendants(matching: .any)["externalLinkProbe"]
            waitUntil(10, "sign-in page handed to the system browser") { opened.label.hasPrefix("https://") }
            app.buttons["otherConnectorPasteCancel"].hit()
            waitGone(paste, timeout: 15, "paste sheet closes")
        } else {
            notice.buttons.firstMatch.tap()
        }
        waitLabel(connect, equals: "Connect")
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "Nous")).firstMatch.exists, "no Nous Portal sign-in copy")
        #endif
    }

    func test6AnEarlierPortalConnectionOffersReconnectAndLeavesOnceConnected() throws {
        let app = launchConnectApps()
        waitForCatalog(app)
        let row = app.descendants(matching: .any)["legacyRow-context7"]
        waitFor(row, timeout: 30, "earlier connection row")
        XCTAssertTrue(app.staticTexts["Reconnect your earlier apps"].exists)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Nous Portal")).firstMatch.exists)
        XCTAssertTrue(app.buttons["legacyRow-context7-dismiss"].exists)
        shot(app, "connect-apps-earlier-connections")
        let reconnect = app.buttons["legacyRow-context7-reconnect"]
        waitFor(reconnect, timeout: 10, "Reconnect action")
        reconnect.hit()
        waitGone(row, timeout: 30, "earlier connection row leaves once connected")
        search(app, "Context7")
        let manage = action(app, "context7")
        waitFor(manage, timeout: 30, "Context7 action")
        waitLabel(manage, equals: "Connected")
        manage.hit()
        let disconnect = app.buttons["Disconnect"]
        waitFor(disconnect, timeout: 10, "disconnect confirmation")
        disconnect.hit()
        waitLabel(manage, equals: "Connect")
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
