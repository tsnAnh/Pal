import XCTest

@MainActor
final class CapabilitiesE2ETests: ConnectAppsTestCase {
    private let scripted = "-hermes-test-capabilities"
    private let failFirst = "-hermes-test-capabilities-fail-first"

    private func reveal(_ app: XCUIApplication, _ id: String, timeout: TimeInterval = 30) -> XCUIElement {
        let target = element(app, id: id)
        for _ in 0..<14 where !(target.exists && target.isHittable) { app.swipeUp() }
        waitFor(target, timeout: timeout, id)
        return target
    }

    func test1aGroupsRunNeedsAKeyThenOnThenOff() throws {
        let app = launchConnectApps(extraArguments: [scripted])
        let needsKey = reveal(app, "capabilityGroupCaption-needsKey")
        let on = reveal(app, "capabilityGroupCaption-on")
        let off = reveal(app, "capabilityGroupCaption-off")
        XCTAssertLessThan(needsKey.frame.minY, on.frame.minY, "Needs a key comes before On")
        XCTAssertLessThan(on.frame.minY, off.frame.minY, "On comes before Off")
        for id in ["maps", "deep_search"] {
            waitFor(element(app, id: "capabilityRow-\(id)"), timeout: 10, "\(id) sits in the needs a key group")
            waitFor(app.buttons["capabilitySetKey-\(id)"], timeout: 10, "\(id) has a Set key action")
        }
        XCTAssertFalse(app.buttons["capabilitySetKey-web"].exists, "an On row has no action")
        XCTAssertFalse(app.buttons["capabilitySetKey-browser"].exists, "an Off row without a key has no action")
        shot(app, "capabilities-groups")
    }

    func test1bSetKeyOpensTheSheetAndSavingMovesTheRowToOn() throws {
        let app = launchConnectApps(extraArguments: [scripted])
        let setKey = reveal(app, "capabilitySetKey-maps")
        setKey.hit()
        let field = element(app, id: "capability-key-field")
        waitFor(field, timeout: 15, "the key sheet opens")
        shot(app, "capabilities-key-sheet")
        field.tap()
        field.typeText("fake-placeholder-key")
        app.buttons["capability-key-save-button"].hit()
        waitUntil(20, "the saved row leaves the needs a key group") { !app.buttons["capabilitySetKey-maps"].exists }
        XCTAssertFalse(element(app, id: "capability-key-field").exists, "the sheet closes once the key is saved")
    }

    func test1cALoadFailureOffersTryAgain() throws {
        let app = launchConnectApps(extraArguments: [scripted, failFirst])
        let message = reveal(app, "capabilitiesError")
        XCTAssertTrue(message.exists)
        shot(app, "capabilities-load-failed")
        let retry = app.buttons["capabilitiesRetry"]
        waitFor(retry, timeout: 10, "Try again")
        retry.hit()
        waitFor(element(app, id: "capabilityGroupCaption-needsKey"), timeout: 20, "the list loads after Try again")
        XCTAssertFalse(element(app, id: "capabilitiesError").exists)
    }

    func test1dAddACustomConnectorButtonIsTallEnough() throws {
        let app = launchConnectApps()
        waitForCatalog(app)
        let add = app.buttons["addCustomConnectorButton"]
        for _ in 0..<20 where !(add.exists && add.isHittable) { app.swipeUp() }
        XCTAssertTrue(add.isHittable)
        #if os(macOS)
        XCTAssertGreaterThanOrEqual(add.frame.height, 46, "the Mac button is at least 46 pt high")
        #else
        let compact = app.windows.firstMatch.frame.width < 600
        XCTAssertGreaterThanOrEqual(add.frame.height, compact ? 52 : 46, "the button keeps its design height")
        #endif
        shot(app, "capabilities-add-button")
    }
}
