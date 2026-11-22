import XCTest

@MainActor
final class McpSignInE2ETests: ConnectAppsTestCase {
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id]
    }

    private func openSignIn(mode: String) -> XCUIApplication {
        let app = launchConnectApps(extraArguments: ["-hermes-test-mcp-signin", mode])
        waitForCatalog(app)
        search(app, "Notion")
        let connect = action(app, "notion")
        waitFor(connect, timeout: 30, "Notion action")
        XCTAssertEqual(connect.label, "Connect")
        connect.hit()
        waitFor(element(app, "mcpSignIn"), timeout: 20, "sign-in sheet")
        return app
    }

    private func expectSheetClosed(_ app: XCUIApplication) {
        waitGone(element(app, "mcpSignIn"), timeout: 15, "sign-in sheet closes")
        waitLabel(action(app, "notion"), equals: "Connect", timeout: 15)
    }

    private func expectConnected(_ app: XCUIApplication) {
        waitFor(element(app, "stepFlowSuccess"), timeout: 30, "success state")
        waitLabel(element(app, "stepFlowCalmTitle"), equals: "Notion is connected", timeout: 10)
        shot(app, "mcp-signin-success")
        let done = element(app, "mcpSignInPrimary")
        waitFor(done, timeout: 10, "Done action")
        XCTAssertEqual(done.label, "Done")
        done.hit()
        waitGone(element(app, "mcpSignIn"), timeout: 15, "sheet closes after Done")
    }

    private func pasteReturnedAddress(_ app: XCUIApplication) {
        waitFor(element(app, "mcpSignInPasteTitle"), timeout: 30, "paste screen")
        shot(app, "mcp-signin-paste")
        let opened = element(app, "externalLinkProbe")
        waitUntil(15, "sign-in page handed to the system browser") { opened.label.hasPrefix("https://") }
        let query = URLComponents(string: opened.label)?.queryItems ?? []
        let redirect = query.first(where: { $0.name == "redirect_uri" })?.value ?? ""
        XCTAssertTrue(redirect.hasPrefix("http://127.0.0.1:"), "sign-in page carries the paste redirect address")

        let field = element(app, "mcpSignInPasteField")
        let primary = element(app, "mcpSignInPrimary")
        waitFor(field, timeout: 10, "paste field")
        field.hit()
        field.typeText("hello")
        let status = element(app, "mcpSignInPasteStatus")
        waitLabel(status, equals: "That is not a web address. Copy the address from your browser's address bar.", timeout: 10)
        XCTAssertFalse(primary.isEnabled, "Finish sign-in stays off for something that is not an address")
        shot(app, "mcp-signin-paste-invalid")

        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 5))
        field.typeText("\(redirect)?code=scripted-code&state=scripted-state")
        waitUntil(10, "Finish sign-in turns on for a returned address") { primary.isEnabled }
        primary.hit()
    }

    func test1RefusedAddressShowsOneCalmFailureWithDetails() throws {
        let app = openSignIn(mode: "refuse-redirect")
        #if os(macOS)
        let device = "Mac"
        #else
        let device = "iPhone"
        #endif
        let title = element(app, "mcpSignInStatusTitle")
        waitFor(title, timeout: 30, "failure title")
        shot(app, "mcp-signin-refused-collapsed")
        waitLabel(title, equals: "Notion would not accept this \(device)'s address", timeout: 10)
        waitLabel(
            element(app, "mcpSignInStatusReason"),
            equals: "Notion only allows sign-in on your own computer, and Pal could not open one here.", timeout: 10
        )
        element(app, "mcpSignInStatusDetails").hit()
        let details = element(app, "mcpSignInStatusDetailsText")
        waitFor(details, timeout: 10, "details text")
        for line in ["code: invalid_redirect_uri", "method: mcp.servers.oauth.start", "trace: scriptedtr"] {
            waitLabel(details, contains: line, timeout: 10)
        }
        XCTAssertTrue(element(app, "mcpSignInStatusCopyDetails").exists, "details can be copied")
        let actions = app.buttons.matching(identifier: "mcpSignInStatusAction")
        XCTAssertEqual(actions.count, 1, "exactly one primary action")
        XCTAssertEqual(actions.firstMatch.label, "Try again")
        XCTAssertFalse(element(app, "mcpSignInPrimary").exists, "no second primary in the footer")
        shot(app, "mcp-signin-refused")
    }

    func test2AStaleSignInIsOfferedAgainAndThenConnects() throws {
        let app = openSignIn(mode: "stale-then-connect")
        let title = element(app, "mcpSignInStatusTitle")
        waitFor(title, timeout: 30, "failure title")
        waitLabel(title, equals: "A sign-in was already open", timeout: 10)
        shot(app, "mcp-signin-stale")
        let retry = element(app, "mcpSignInStatusAction")
        XCTAssertEqual(retry.label, "Connect")
        retry.hit()
        #if os(macOS)
        expectConnected(app)
        #else
        pasteReturnedAddress(app)
        expectConnected(app)
        #endif
    }

    func test3AnAdminGateShowsTheCalmWaitingState() throws {
        let app = openSignIn(mode: "admin")
        waitFor(element(app, "stepFlowCalmTitle"), timeout: 30, "waiting for admin state")
        waitLabel(element(app, "stepFlowCalmTitle"), equals: "Waiting for your admin", timeout: 10)
        shot(app, "mcp-signin-admin")
        XCTAssertFalse(element(app, "mcpSignInPrimary").exists, "the toolbar Close is the only way out")
        let close = element(app, "mcpSignInClose")
        waitFor(close, timeout: 10, "Close action")
        XCTAssertEqual(close.label, "Close")
        close.hit()
        expectSheetClosed(app)
    }

    func test3bAdminWordsWithoutTheGatewayStateStayAPlainFailure() throws {
        let app = openSignIn(mode: "admin-words")
        let title = element(app, "mcpSignInStatusTitle")
        waitFor(title, timeout: 30, "failure title")
        waitLabel(title, equals: "Sign-in did not finish", timeout: 10)
        XCTAssertFalse(element(app, "stepFlowCalmTitle").exists, "no waiting-for-admin state without the gateway saying so")
        element(app, "mcpSignInStatusDetails").hit()
        waitLabel(element(app, "mcpSignInStatusDetailsText"), contains: "code: access_denied", timeout: 10)
        shot(app, "mcp-signin-admin-words")
    }

    func test4CancellingWhileWaitingClosesTheSheetAndLeavesTheRowUnchanged() throws {
        #if os(macOS)
        let app = openSignIn(mode: "wait")
        waitFor(element(app, "stepFlowWaiting"), timeout: 30, "waiting for the browser")
        waitLabel(element(app, "stepFlowCalmTitle"), equals: "Waiting for you in the browser", timeout: 10)
        waitLabel(element(app, "stepFlowPosition"), equals: "Step 2 of 3", timeout: 10)
        XCTAssertFalse(element(app, "stepFlowChecklist").exists, "Mac shows the progress bar, not the checklist rail")
        #else
        let app = openSignIn(mode: "connect")
        waitFor(element(app, "mcpSignInPasteTitle"), timeout: 30, "paste screen")
        if element(app, "stepFlowChecklist").exists {
            waitFor(element(app, "stepFlowRow-signin"), timeout: 10, "sign-in row")
        } else {
            waitLabel(element(app, "stepFlowPosition"), equals: "Step 2 of 3", timeout: 10)
        }
        #endif
        shot(app, "mcp-signin-waiting")
        element(app, "mcpSignInCancel").hit()
        expectSheetClosed(app)
    }
}
