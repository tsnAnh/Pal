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

    private func search(_ app: XCUIApplication, _ text: String) {
        let field = app.descendants(matching: .any)["connectAppsSearch"]
        for _ in 0..<20 where !field.isHittable { app.swipeDown() }
        field.hit()
        field.typeText(text)
    }

    private func action(_ app: XCUIApplication, _ slug: String) -> XCUIElement {
        app.buttons["connectApp-connector:\(slug)-action"]
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
        waitLabel(connect, contains: "Manage")
        shot(app, "connect-apps-direct-connected")
        connect.hit()
        let disconnect = app.buttons["Disconnect"]
        waitFor(disconnect, timeout: 10, "disconnect confirmation")
        disconnect.hit()
        waitLabel(connect, contains: "Connect")
    }

    func test4AnAppThatNeedsSetupOffersTheSetUpSheetWithNoPortalCopy() throws {
        let app = launchConnectApps()
        waitForCatalog(app)
        search(app, "Asana")
        let row = app.descendants(matching: .any)["connectApp-connector:asana"]
        waitFor(row, timeout: 30, "Asana row")
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "Nous")).firstMatch.exists, "no Nous Portal sign-in copy")
        let setUp = action(app, "asana")
        waitFor(setUp, timeout: 10, "Asana set up action")
        XCTAssertEqual(setUp.label, "Set up")
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
        waitLabel(connect, contains: "Connect")
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "Nous")).firstMatch.exists, "no Nous Portal sign-in copy")
        #endif
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

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id]
    }

    private func enterClient(_ app: XCUIApplication, redirect: String) {
        let sheet = element(app, "oauthClientSetup")
        waitFor(sheet, timeout: 20, "set up sheet")
        let address = element(app, "oauthClientRedirect")
        waitFor(address, timeout: 20, "redirect URL")
        XCTAssertEqual(address.label, redirect, "the redirect URL is shown exactly")
        waitFor(element(app, "oauthClientCopyRedirect"), timeout: 5, "copy button")
        let save = element(app, "oauthClientSave")
        for _ in 0..<6 where !save.isHittable { app.swipeUp() }
        XCTAssertFalse(save.isEnabled, "Save waits for both fields")
        element(app, "oauthClientID").hit()
        element(app, "oauthClientID").typeText("fake-client-id")
        element(app, "oauthClientSecret").hit()
        element(app, "oauthClientSecret").typeText("fake-token-do-not-use")
        for _ in 0..<6 where !save.isHittable { app.swipeUp() }
        XCTAssertTrue(save.isEnabled, "Save is ready with both fields")
        shot(app, "oauth-client-setup")
        save.hit()
        waitGone(sheet, timeout: 20, "set up sheet closes after saving")
    }

    private func openedLink(_ app: XCUIApplication, prefix: String) {
        let opened = element(app, "externalLinkProbe")
        waitUntil(30, "sign-in page handed to the system browser") { opened.label.hasPrefix(prefix) }
    }

    func test6AsanaGoesFromNeedsSetupToConnectedAndBack() throws {
        let app = launchConnectApps(extraArguments: ["-hermes-test-oauth-client"])
        waitForCatalog(app)
        search(app, "Asana")
        let button = action(app, "asana")
        waitFor(button, timeout: 30, "Asana action")
        XCTAssertEqual(button.label, "Set up")
        button.hit()
        enterClient(app, redirect: "http://localhost:27890/callback")
        waitLabel(button, contains: "Connect")
        button.hit()
        openedLink(app, prefix: "https://app.asana.com/")
        let state = "state=scripted-state"
        #if os(macOS)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:27890/callback?code=fake-token-do-not-use&\(state)")!)
        request.setValue("localhost:27890", forHTTPHeaderField: "Host")
        let returned = expectation(description: "redirect delivered")
        URLSession.shared.dataTask(with: request) { _, _, _ in returned.fulfill() }.resume()
        wait(for: [returned], timeout: 15)
        #else
        let paste = element(app, "otherConnectorPaste")
        waitFor(paste, timeout: 20, "paste sheet")
        let field = element(app, "other-paste-field")
        field.hit()
        field.typeText("http://localhost:27890/callback?code=fake-token-do-not-use&\(state)")
        element(app, "other-paste-submit").hit()
        waitGone(paste, timeout: 20, "paste sheet closes")
        #endif
        waitLabel(button, contains: "Remove")
        shot(app, "oauth-client-asana-connected")
        button.hit()
        let confirm = app.buttons["Disconnect"]
        waitFor(confirm, timeout: 10, "remove confirmation")
        confirm.hit()
        waitLabel(button, contains: "Connect")
    }

    func test7GoogleGoesFromNeedsSetupToConnectedThroughTheGatewayPage() throws {
        let app = launchConnectApps(extraArguments: ["-hermes-test-oauth-client"])
        waitForCatalog(app)
        search(app, "Google Workspace")
        let button = action(app, "google-workspace")
        waitFor(button, timeout: 30, "Google Workspace action")
        XCTAssertEqual(button.label, "Set up")
        button.hit()
        enterClient(app, redirect: "https://pal.example.test/webapp/google-install/callback")
        waitLabel(button, contains: "Connect")
        button.hit()
        openedLink(app, prefix: "https://accounts.google.com/")
        waitLabel(button, contains: "Remove", timeout: 45)
        shot(app, "oauth-client-google-connected")
    }

    func test8GoogleSetUpWithoutAPublicAddressShowsTheGuidedStatus() throws {
        let app = launchConnectApps(extraArguments: ["-hermes-test-oauth-client", "-hermes-test-oauth-client-no-public-address"])
        waitForCatalog(app)
        search(app, "Google Workspace")
        let button = action(app, "google-workspace")
        waitFor(button, timeout: 30, "Google Workspace action")
        button.hit()
        let status = element(app, "oauthClientStatus")
        waitFor(status, timeout: 20, "status block")
        let title = app.staticTexts["Public address needed"]
        let primary = element(app, "oauthClientPrimary")
        waitFor(title, timeout: 10, "status title")
        waitFor(primary, timeout: 10, "try again action")
        XCTAssertGreaterThan(primary.frame.minY, title.frame.maxY, "the action is below the text")
        XCTAssertLessThanOrEqual(primary.frame.minY - title.frame.maxY, 160, "the action sits right under the text")
        XCTAssertLessThanOrEqual(status.frame.width, 440, "the block keeps a readable width")
        XCTAssertFalse(element(app, "oauthClientRedirect").exists, "no redirect field without a public address")
        element(app, "oauthClientDetails").hit()
        waitFor(element(app, "oauthClientCopyDetails"), timeout: 10, "copy button")
        XCTAssertEqual(element(app, "oauthClientReasonCode").label, "NEEDS_PUBLIC_URL", "details name the reason code")
        XCTAssertTrue(app.staticTexts["Set this gateway's public address first."].exists)
        shot(app, "oauth-client-needs-public-address")
    }
}
