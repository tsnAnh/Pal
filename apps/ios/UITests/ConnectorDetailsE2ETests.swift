import PalDesign
import XCTest

@MainActor
final class ConnectorDetailsE2ETests: ConnectAppsTestCase {
    private let script = "-hermes-test-connector-details"

    private func open(_ app: XCUIApplication, _ slug: String) {
        let connected = ["linear", "upwork", "github-mcp"].contains(slug)
        if connected {
            let installed = app.buttons["connectAppsInstalledButton"]
            waitFor(installed, timeout: 30, "connected count button")
            installed.hit()
        }
        let row = app.buttons[connected ? "connectInstalled-connector:\(slug)-open" : "connectApp-connector:\(slug)-open"]
        for _ in 0..<8 where !row.exists || !row.isHittable { app.swipeUp() }
        waitFor(row, timeout: 30, "\(slug) row")
        row.hit()
        waitFor(element(app, "connectorDetails"), timeout: 20, "details of \(slug)")
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func reveal(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        let target = element(app, identifier)
        for _ in 0..<8 where !target.exists || !target.isHittable { app.swipeUp() }
        waitFor(target, timeout: 10, identifier)
        return target
    }

    private func scrollToTop(_ app: XCUIApplication) {
        for _ in 0..<6 { app.swipeDown() }
    }

    func test1RowPushesDetailsAndBackReturnsToConnectApps() throws {
        let app = launchConnectApps(appearance: .light, extraArguments: [script])
        waitForCatalog(app)
        shot(app, "details-01-connect-apps-light")
        #if os(iOS)
        XCTAssertTrue(app.buttons["connectApps-close"].exists, "Connect Apps root offers Close")
        #endif
        open(app, "notion-mcp")
        waitFor(app.buttons["connectorDetailsConnect"], timeout: 10, "details of an unconnected app")
        #if os(iOS)
        XCTAssertFalse(app.buttons["connectApps-close"].isHittable, "details has only the system back")
        XCTAssertGreaterThan(app.navigationBars.buttons.count, 0, "system back button")
        #endif
        shot(app, "details-01b-notion-light")
        goBackFromDetails(app)
        waitFor(element(app, "connectApps"), timeout: 10, "Connect Apps root")
        #if os(iOS)
        XCTAssertTrue(app.buttons["connectApps-close"].isHittable, "root offers Close again")
        #endif
        shot(app, "details-01c-back-on-connect-apps-light")
        open(app, "linear")
        XCTAssertEqual(element(app, "connectorDetailsName").label, "Linear")
        #if os(iOS)
        XCTAssertFalse(app.buttons["connectApps-close"].isHittable, "details has only the system back")
        XCTAssertGreaterThan(app.navigationBars.buttons.count, 0, "system back button")
        #endif
        waitFor(element(app, "connectorAccount-default"), timeout: 20, "default account")
        waitFor(element(app, "connectorToolsGroup-tool"), timeout: 20, "tools group")
        shot(app, "details-02-linear-light")
        goBackFromDetails(app)
        waitFor(app.buttons["connectInstalled-connector:linear-open"], timeout: 10, "connected screen again")
        shot(app, "details-03-back-on-connected-light")
    }

    func test2SwipeBackReturnsToConnectApps() throws {
        #if os(macOS)
        throw XCTSkip("The edge swipe is an iPhone and iPad gesture")
        #else
        let app = launchConnectApps(extraArguments: [script])
        waitForCatalog(app)
        open(app, "notion-mcp")
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
        waitGone(element(app, "connectorDetails"), timeout: 10, "edge swipe pops the details")
        waitFor(element(app, "connectApps"), timeout: 10, "Connect Apps root")
        #endif
    }

    func test3SeveralAccountsShowEachStatusAndGroupedTools() throws {
        let app = launchConnectApps(extraArguments: [script])
        waitForCatalog(app)
        open(app, "upwork")
        waitLabel(element(app, "connectorAccountStatus-work"), contains: "Connected")
        waitLabel(element(app, "connectorAccountStatus-personal"), contains: "Needs sign-in")
        waitFor(element(app, "connectorToolsGroup-read"), timeout: 20, "Reads")
        XCTAssertTrue(element(app, "connectorToolsGroup-write").exists)
        XCTAssertTrue(element(app, "connectorToolsGroup-never").exists)
        XCTAssertFalse(element(app, "connectorDetailsSkills").exists, "no Skills card when no skill uses the connector")
        shot(app, "details-04-upwork-several-accounts")
        let footnote = reveal(app, "connectorDetailsToolsFootnote")
        XCTAssertTrue(footnote.label.contains("Writes always ask first"))
        shot(app, "details-05-upwork-tools-and-information")
        let source = reveal(app, "connectorDetailsInfo-source")
        XCTAssertEqual(source.label, "Setup guide")
        XCTAssertEqual(element(app, "connectorDetailsInfo-address").label, "mcp.upwork.com")
    }

    func test4ReadMenuOffersThreeModesWriteMenuTwo() throws {
        let app = launchConnectApps(extraArguments: [script])
        waitForCatalog(app)
        open(app, "upwork")
        let reads = reveal(app, "connectorToolsPolicy-read")
        reads.hit()
        waitFor(app.buttons["connectorToolsPolicy-read-auto"], timeout: 10, "Runs without asking")
        XCTAssertTrue(app.buttons["connectorToolsPolicy-read-ask"].exists)
        shot(app, "details-06-reads-menu")
        app.buttons["connectorToolsPolicy-read-off"].hit()
        waitUntil(15, "reads policy reads Off") { self.element(app, "connectorToolsPolicy-read").value as? String == "Off" }
        let writes = reveal(app, "connectorToolsPolicy-write")
        writes.hit()
        waitFor(app.buttons["connectorToolsPolicy-write-ask"], timeout: 10, "Ask first")
        XCTAssertTrue(app.buttons["connectorToolsPolicy-write-off"].exists)
        XCTAssertFalse(app.buttons["connectorToolsPolicy-write-auto"].exists, "writes never offer Runs without asking")
        shot(app, "details-07-writes-menu")
        app.buttons["connectorToolsPolicy-write-ask"].hit()
    }

    func test5GroupsExpandToToolNamesAndNeverIsLocked() throws {
        let app = launchConnectApps(extraArguments: [script])
        waitForCatalog(app)
        open(app, "upwork")
        reveal(app, "connectorToolsGroup-read").hit()
        waitFor(element(app, "connectorTool-search_jobs"), timeout: 10, "read tool row")
        let more = reveal(app, "connectorToolsShowAll-read")
        shot(app, "details-08-reads-expanded")
        more.hit()
        waitFor(element(app, "connectorTool-read_messages"), timeout: 10, "all reads shown")
        reveal(app, "connectorToolsGroup-never").hit()
        waitFor(element(app, "connectorTool-pay_invoice"), timeout: 10, "never tool row")
        XCTAssertFalse(app.buttons["connectorToolsPolicy-never"].exists, "Never allowed has no menu")
    }

    func test6AddAccountIsInlineWithValidation() throws {
        let app = launchConnectApps(appearance: .light, extraArguments: [script])
        waitForCatalog(app)
        open(app, "linear")
        reveal(app, "connectorAccountAdd").hit()
        let field = element(app, "connectorAccountAddField")
        waitFor(field, timeout: 10, "add account field")
        XCTAssertFalse(app.buttons["connectorAccountAddConnect"].isEnabled, "Connect stays dim until the name is valid")
        shot(app, "details-09-add-account-field-light")
        field.typeText("Work Team")
        waitFor(element(app, "connectorAccountAddProblem"), timeout: 10, "validation message")
        XCTAssertEqual(element(app, "connectorAccountAddProblem").label, "Use only lowercase letters, numbers and hyphens.")
        XCTAssertFalse(app.buttons["connectorAccountAddConnect"].isEnabled)
        shot(app, "details-10-add-account-invalid-light")
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 9))
        field.typeText("personal")
        waitUntil(10, "Connect enables for a valid name") { app.buttons["connectorAccountAddConnect"].isEnabled }
        shot(app, "details-11-add-account-valid-light")
        app.buttons["connectorAccountAddCancel"].hit()
        waitGone(field, timeout: 10, "field collapses")
        XCTAssertTrue(element(app, "connectorAccountAdd").exists)
    }

    func test7RenameIsInlineAndRefusesATakenName() throws {
        let app = launchConnectApps(extraArguments: [script])
        waitForCatalog(app)
        open(app, "upwork")
        reveal(app, "connectorAccountRename-work").hit()
        let field = element(app, "connectorAccountRenameField-work")
        waitFor(field, timeout: 10, "rename field")
        field.typeText(XCUIKeyboardKey.delete.rawValue + XCUIKeyboardKey.delete.rawValue + XCUIKeyboardKey.delete.rawValue + XCUIKeyboardKey.delete.rawValue)
        field.typeText("personal")
        waitFor(element(app, "connectorAccountRenameProblem-work"), timeout: 10, "taken name message")
        XCTAssertEqual(element(app, "connectorAccountRenameProblem-work").label, "You already have an account with that name.")
        shot(app, "details-12-rename-taken")
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 8))
        field.typeText("work-team")
        app.buttons["connectorAccountRenameSave-work"].hit()
        waitFor(element(app, "connectorAccount-work-team"), timeout: 20, "renamed account")
        XCTAssertFalse(element(app, "connectorAccount-work").exists)
    }

    func test8MenuRemoveOnTheLastAccountAsksToDisconnect() throws {
        let app = launchConnectApps(extraArguments: [script])
        waitForCatalog(app)
        open(app, "github-mcp")
        reveal(app, "connectorAccountMenu-work").hit()
        let remove = app.buttons["connectorAccountRemove-work"]
        waitFor(remove, timeout: 10, "Remove in the account menu")
        XCTAssertTrue(app.buttons["connectorAccountSignIn-work"].exists)
        shot(app, "details-13-account-menu")
        remove.hit()
        let confirm = app.buttons["Disconnect"]
        waitFor(confirm, timeout: 10, "disconnect confirmation")
        shot(app, "details-14-disconnect-confirm")
        app.buttons["Cancel"].firstMatch.hit()
        XCTAssertTrue(element(app, "connectorAccount-work").exists, "cancelling keeps the account")
    }

    func test9NotConnectedShowsConnectAndInformationOnly() throws {
        let app = launchConnectApps(extraArguments: [script])
        waitForCatalog(app)
        open(app, "notion-mcp")
        waitFor(app.buttons["connectorDetailsConnect"], timeout: 10, "Connect")
        XCTAssertFalse(element(app, "connectorDetailsAccounts").exists)
        XCTAssertFalse(element(app, "connectorDetailsTools").exists)
        waitFor(element(app, "connectorDetailsNotConnectedNote"), timeout: 10, "note")
        shot(app, "details-15-not-connected")
    }

    func test10DarkRootAndInstalledOriginsEachReturnWhereTheyStarted() throws {
        let app = launchConnectApps(appearance: .dark, extraArguments: [script])
        waitForCatalog(app)
        shot(app, "details-16-root-dark")
        open(app, "notion-mcp")
        shot(app, "details-17-root-origin-details-dark")
        goBackFromDetails(app)
        waitFor(element(app, "connectApps"), timeout: 10, "Connect Apps root")
        shot(app, "details-18-back-on-root-dark")
        open(app, "linear")
        waitFor(element(app, "connectorAccount-default"), timeout: 20, "default account")
        shot(app, "details-19-installed-origin-details-dark")
        goBackFromDetails(app)
        waitFor(app.buttons["connectInstalled-connector:linear-open"], timeout: 10, "connected screen again")
        shot(app, "details-20-back-on-installed-dark")
    }
}
