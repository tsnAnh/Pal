import XCTest

private struct ClientApp {
    let name: String
    let slug: String
    let openTitle: String
    let page: String
    let authorize: String
    let scopes: String
    let rejectsOnce: Bool

    static let figma = ClientApp(
        name: "Figma", slug: "figma", openTitle: "Open Figma developer settings", page: "https://www.figma.com/developers/apps",
        authorize: "https://www.figma.com/oauth", scopes: "file_content:read", rejectsOnce: false
    )
    static let dropbox = ClientApp(
        name: "Dropbox", slug: "dropbox", openTitle: "Open Dropbox App Console", page: "https://www.dropbox.com/developers/console/apps",
        authorize: "https://www.dropbox.com/oauth2/authorize", scopes: "files.metadata.read", rejectsOnce: false
    )
    static let canva = ClientApp(
        name: "Canva", slug: "canva", openTitle: "Open Canva developer portal", page: "https://www.canva.com/developers/apps",
        authorize: "https://www.canva.com/api/oauth/authorize", scopes: "design:content:read", rejectsOnce: true
    )

    var pasteTitle: String { "Paste the two values \(name) shows" }
}

@MainActor
final class OwnerSetupClientE2ETests: ConnectAppsTestCase {
    private let mcpRedirect = "https://pal.example.test/webapp/mcp-oauth/callback"
    private let clientID = "fake-client-id"
    private let goodSecret = "fake-token-do-not-use"
    private let badSecret = "rejected-secret-do-not-use"

    private let signInNumber = 4

    private var totalRows: Int {
        #if os(macOS)
        4
        #else
        5
        #endif
    }

    private func walkToTheClient(_ setup: OwnerSetupDriver, _ client: ClientApp) {
        setup.expectIntro("Set up \(client.name)")
        shot(setup.app, "owner-setup-\(client.slug)-intro")
        setup.primary("Start")
        setup.expectStep("app", client.openTitle, number: 1, of: totalRows)
        XCTAssertEqual(setup.el("stepFlowSkip").label, "I already have one")
        setup.primary(client.openTitle)
        setup.expectOpened(client.page)
        setup.expectStep("app-copy", "Create the app and paste the redirect address", number: 2, of: totalRows)
        setup.expectCopy(0, equals: mcpRedirect)
        let scopes = setup.el("stepFlowCopy-1Value")
        waitFor(scopes, timeout: 10, "scopes to copy")
        XCTAssertTrue(scopes.label.contains(client.scopes), "the scopes are ready to copy")
        waitFor(setup.el("ownerSetupAddressReachable"), timeout: 20, "reachability note")
        shot(setup.app, "owner-setup-\(client.slug)-redirect")
        setup.primary("Next")
        setup.expectStep("client", client.pasteTitle, number: 3, of: totalRows)
    }

    private func saveClient(_ setup: OwnerSetupDriver, _ client: ClientApp) {
        setup.expectPrimary(enabled: false, "Check and save waits for both fields")
        setup.enter("client_id", clientID)
        setup.enter("client_secret", client.rejectsOnce ? badSecret : goodSecret)
        setup.expectValid("client_id")
        setup.expectValid("client_secret")
        setup.expectPrimary(enabled: true, "Check and save is ready with both fields")
        setup.primary("Check and save")
        guard client.rejectsOnce else { return }
        setup.expectRejected(
            code: "INVALID_CLIENT", title: "\(client.name) did not accept that client", action: "Edit client",
            shot: "owner-setup-\(client.slug)-rejected"
        )
        setup.clear("client_secret", removing: badSecret)
        setup.enter("client_secret", goodSecret)
        setup.primary("Check and save")
    }

    private func signIn(_ setup: OwnerSetupDriver, _ client: ClientApp) {
        setup.expectStep("signin", "Sign in to \(client.name)", number: signInNumber, of: totalRows)
        XCTAssertTrue(setup.el("ownerSetupReplace").exists && setup.el("ownerSetupRemove").exists, "the saved client can be replaced or removed")
        shot(setup.app, "owner-setup-\(client.slug)-signin")
        setup.primary("Sign in with \(client.name)")
        #if os(macOS)
        setup.expectWaiting("Waiting for \(client.name)")
        #endif
        setup.expectOpened(client.authorize)
        setup.returnFromBrowser()
        setup.expectConnected("\(client.name) is connected")
        shot(setup.app, "owner-setup-\(client.slug)-connected")
    }

    private func connect(_ client: ClientApp) {
        let app = launchConnectApps(extraArguments: ["-hermes-test-oauth-client"])
        let setup = OwnerSetupDriver(test: self, app: app)
        let button = setup.open(client.name, slug: client.slug)
        walkToTheClient(setup, client)
        saveClient(setup, client)
        signIn(setup, client)
        setup.finish(button, reads: "Connected")
    }

    private func saveFigmaClient() -> (OwnerSetupDriver, XCUIElement) {
        let app = launchConnectApps(extraArguments: ["-hermes-test-oauth-client"])
        let setup = OwnerSetupDriver(test: self, app: app)
        let button = setup.open("Figma", slug: "figma")
        setup.primary("Start")
        setup.expectStep("app", ClientApp.figma.openTitle, number: 1, of: totalRows)
        setup.el("stepFlowSkip").hit()
        setup.expectStep("client", ClientApp.figma.pasteTitle, number: 3, of: totalRows)
        setup.enter("client_id", clientID)
        setup.enter("client_secret", goodSecret)
        setup.primary("Check and save")
        setup.expectStep("signin", "Sign in to Figma", number: signInNumber, of: totalRows)
        return (setup, button)
    }

    private func reopenSavedFigma(_ setup: OwnerSetupDriver, _ button: XCUIElement) {
        setup.close()
        waitLabel(button, equals: "Connect", timeout: 30)
        button.hit()
        waitFor(setup.el("stepFlow"), timeout: 30, "step flow")
        setup.expectStep("signin", "Sign in to Figma", number: signInNumber, of: totalRows)
        XCTAssertFalse(setup.el("stepFlowIntro").exists, "a saved client skips the intro")
        waitFor(setup.el("ownerSetupReplace"), timeout: 10, "replace action")
        waitFor(setup.el("ownerSetupRemove"), timeout: 10, "remove action")
        shot(setup.app, "owner-setup-figma-resumed")
    }

    private func answerAlert(_ app: XCUIApplication, mentions text: String, taps title: String) {
        let alert = app.alerts.firstMatch
        waitFor(alert, timeout: 10, "confirmation")
        XCTAssertTrue(alert.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", text)).firstMatch.exists, "the alert names \(text)")
        alert.buttons[title].hit()
        waitGone(alert, timeout: 10, "confirmation closes")
    }

    func test1FigmaGuidesTheAppThenSavesTheClientWithoutATestCall() throws {
        connect(.figma)
    }

    func test2DropboxGuidesTheAppThenSavesTheClientWithoutATestCall() throws {
        connect(.dropbox)
    }

    func test3CanvaGuidesTheAppRejectsTheClientThenSavesAndConnects() throws {
        connect(.canva)
    }

    func test4ASavedClientResumesAtSignInAndReplaceGoesBackToThePasteStep() throws {
        let (setup, button) = saveFigmaClient()
        reopenSavedFigma(setup, button)
        setup.reveal("ownerSetupReplace").hit()
        answerAlert(setup.app, mentions: "saved client", taps: "Cancel")
        setup.expectStep("signin", "Sign in to Figma", number: signInNumber, of: totalRows)
        setup.reveal("ownerSetupReplace").hit()
        answerAlert(setup.app, mentions: "saved client", taps: "Replace")
        setup.expectStep("client", ClientApp.figma.pasteTitle, number: 3, of: totalRows)
        waitGone(setup.el("ownerSetupReplace"), timeout: 10, "replace belongs to the sign-in step")
        setup.expectPrimary(enabled: false, "the new client starts empty")
        shot(setup.app, "owner-setup-figma-replace")
    }

    func test5RemovingTheSavedClientReturnsToTheFirstStep() throws {
        let (setup, button) = saveFigmaClient()
        reopenSavedFigma(setup, button)
        setup.reveal("ownerSetupRemove").hit()
        answerAlert(setup.app, mentions: "Figma", taps: "Remove client")
        setup.expectStep("app", ClientApp.figma.openTitle, number: 1, of: totalRows)
        XCTAssertFalse(setup.el("ownerSetupRemove").exists, "nothing left to remove")
        XCTAssertFalse(setup.el("stepFlowBack").exists, "the first step has no way back")
        shot(setup.app, "owner-setup-figma-removed")
        setup.close()
        waitLabel(button, equals: "Set up", timeout: 30)
    }
}
