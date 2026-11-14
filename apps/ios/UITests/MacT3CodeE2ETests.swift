#if os(macOS)
import PalDesign
import XCTest

@MainActor
final class MacT3CodeE2ETests: BotProfileTestCase {
    private var scratch: URL!

    override func setUp() async throws {
        try await super.setUp()
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("pal-t3-ui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch.appendingPathComponent("userdata"), withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: scratch)
        try await super.tearDown()
    }

    private func publishRuntime(port: Int = 1) throws {
        let body = #"{"version":1,"pid":\#(ProcessInfo.processInfo.processIdentifier),"origin":"http://127.0.0.1:\#(port)"}"#
        try Data(body.utf8).write(to: scratch.appendingPathComponent("userdata/server-runtime.json"))
    }

    private func openConnectApps() -> XCUIApplication {
        let app = launch(extraArguments: [
            "-hermes-open-connect-apps", "-hermes-record-external-links",
            "-\(AppearanceStore.defaultsKey)", AppearanceMode.dark.rawValue,
            "-hermes-test-t3-base-dir", scratch.path,
        ])
        let sheet = element(app, "connectApps")
        if !sheet.waitForExistence(timeout: 25) { signInIfNeeded(app) }
        waitFor(sheet, timeout: 40, "connect apps panel")
        return app
    }

    private func summary(_ app: XCUIApplication) -> XCUIElement {
        element(app, "deviceConnector-t3code-summary")
    }

    func test1NotRunningAsksToOpenT3Code() throws {
        let app = openConnectApps()
        let row = element(app, "deviceConnector-t3code")
        waitFor(row, timeout: 30, "T3 Code row in This Mac")
        waitUntil(15, "summary reads Open T3 Code to connect") { self.summary(app).label == "Open T3 Code to connect" }
        let action = app.buttons["deviceConnector-t3code-action"]
        waitFor(action, timeout: 10, "open button")
        XCTAssertEqual(action.label, "Open T3 Code")
        XCTAssertTrue(app.staticTexts["T3 Code"].exists)
        shot(app, "t3code-not-running")
    }

    func test2RunningServerWithoutSignInOffersConnectThenShowsTheFailureReason() throws {
        try publishRuntime()
        let app = openConnectApps()
        let action = app.buttons["deviceConnector-t3code-action"]
        waitFor(action, timeout: 30, "connect button")
        waitUntil(15, "button reads Connect") { action.label == "Connect" }
        shot(app, "t3code-signed-out")
        action.hit()
        waitUntil(30, "failure reason shown") { self.summary(app).label == "We couldn't reach the sign-in service." }
        XCTAssertEqual(app.buttons["deviceConnector-t3code-action"].label, "Try again")
        shot(app, "t3code-failed")
    }
}
#endif
