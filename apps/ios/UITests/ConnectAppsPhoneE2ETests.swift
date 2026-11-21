import XCTest

@MainActor
final class ConnectAppsPhoneE2ETests: ConnectAppsTestCase {
    func test7PhoneLayoutChipSearchManageAndBack() throws {
        #if os(macOS)
        throw XCTSkip("Mac has its own panel layout")
        #else
        let app = launchConnectApps()
        waitForCatalog(app)
        assertPhoneChrome(app)
        selectChips(app)
        searchAndConnect(app, "Deepwiki")
        showNoResults(app, replacing: "Deepwiki")
        openInstalledAndBack(app)
        search(app, "Deepwiki")
        let row = app.buttons["connectApp-connector:deepwiki-open"]
        waitFor(row, timeout: 30, "connected Deepwiki row opens the details")
        row.hit()
        let disconnect = app.buttons["connectorDetailsDisconnect"]
        waitFor(disconnect, timeout: 15, "details Disconnect")
        disconnect.hit()
        confirmDisconnect(app)
        waitFor(app.buttons["connectorDetailsConnect"], timeout: 30, "details flips to not connected")
        goBackFromDetails(app)
        waitLabel(action(app, "deepwiki"), equals: "Connect")
        #endif
    }

    private func assertPhoneChrome(_ app: XCUIApplication) {
        waitFor(element(app, id: "connectAppsChips"), timeout: 20, "chip row")
        waitFor(app.buttons["connectApps-close"], timeout: 10, "close button")
        waitFor(element(app, id: "connectAppsSearch"), timeout: 10, "floating search")
        XCTAssertTrue(app.staticTexts["Connect apps"].exists, "title")
    }

    private func selectChips(_ app: XCUIApplication) {
        let all = app.buttons["connectAppsChip-all"]
        waitFor(all, timeout: 10, "All chip")
        XCTAssertTrue(all.isSelected, "All starts selected")
        let device = app.buttons["connectAppsChip-device"]
        waitFor(device, timeout: 10, "This device chip")
        device.tap()
        XCTAssertTrue(device.isSelected, "the device chip selects")
        XCTAssertFalse(all.isSelected, "All deselects")
        all.tap()
        let prefix = "connectAppsChip-"
        let reserved = ["all", "device", "more"].map { prefix + $0 }
        let format = "identifier BEGINSWITH %@ AND NOT identifier IN %@"
        let categories = app.buttons.matching(NSPredicate(format: format, prefix, reserved))
        waitFor(categories.firstMatch, timeout: 10, "a category chip")
        let category = categories.firstMatch
        let name = String(category.identifier.dropFirst(prefix.count))
        category.tap()
        XCTAssertTrue(category.isSelected, "the category chip selects")
        waitFor(element(app, id: "connectAppsSection-\(name)"), timeout: 10, "the category section")
        shot(app, "connect-apps-phone-category")
        all.tap()
    }

    private func searchAndConnect(_ app: XCUIApplication, _ text: String) {
        search(app, text)
        waitFor(element(app, id: "connectApp-connector:deepwiki"), timeout: 30, "Deepwiki result")
        XCTAssertFalse(app.buttons["connectAppsChip-all"].isSelected, "no chip is selected while searching")
        let connect = action(app, "deepwiki")
        waitFor(connect, timeout: 30, "Deepwiki action")
        XCTAssertEqual(connect.label, "Connect")
        connect.hit()
        waitLabel(app.buttons["connectApp-connector:deepwiki-open"], contains: "Connected")
    }

    private func showNoResults(_ app: XCUIApplication, replacing old: String) {
        let field = element(app, id: "connectAppsSearch")
        let missing = "zzzz no such app"
        field.hit()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count))
        field.typeText(missing)
        let noMatches = element(app, id: "connectAppsNoMatches")
        waitFor(noMatches, timeout: 10, "no results state")
        let echoed = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", missing)).firstMatch
        XCTAssertTrue(echoed.exists, "the query shows in the empty state")
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: missing.count))
        waitGone(noMatches, timeout: 10, "no results state clears")
        waitFor(element(app, id: "connectAppsChips"), timeout: 10, "chip row after clearing")
    }

    private func openInstalledAndBack(_ app: XCUIApplication) {
        let installed = app.buttons["connectAppsInstalledButton"]
        waitFor(installed, timeout: 20, "N connected pill")
        waitLabel(installed, contains: "connected")
        installed.tap()
        waitFor(element(app, id: "connectAppsInstalled"), timeout: 10, "manage screen")
        waitFor(element(app, id: "connectInstalled-connector:deepwiki"), timeout: 10, "connected Deepwiki row")
        assertOneSystemWayOut(app, screen: "manage screen", close: "connectAppsInstalledClose", back: "connectAppsInstalledBack")
        shot(app, "connect-apps-phone-installed")
        #if os(iOS)
        app.buttons["BackButton"].tap()
        #else
        app.buttons["connectAppsInstalledBack"].tap()
        #endif
        waitGone(element(app, id: "connectAppsInstalled"), timeout: 10, "manage screen leaves")
        waitFor(element(app, id: "connectAppsChips"), timeout: 10, "list returns")
        waitFor(element(app, id: "connectAppsSearch"), timeout: 10, "search returns once the pop settles")
        shot(app, "connect-apps-after-back")
    }
}
