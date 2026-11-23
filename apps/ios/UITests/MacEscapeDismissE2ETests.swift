#if os(macOS)
import XCTest

@MainActor
final class MacEscapeDismissE2ETests: BotProfileTestCase {
    private func openSettings(_ app: XCUIApplication) {
        app.typeKey(",", modifierFlags: .command)
        waitFor(element(app, "settingsSheet"), timeout: 15, "settings panel")
    }

    private func openVaultAddSheet(_ app: XCUIApplication) {
        openSettings(app)
        let vault = app.buttons["macSettingsSection-vault"]
        waitFor(vault, timeout: 10, "vault section")
        vault.hit()
        let add = app.buttons["vaultAddButton"]
        waitFor(add, timeout: 10, "new item button")
        add.hit()
        waitFor(element(app, "vaultAddSheet"), timeout: 10, "vault add sheet")
    }

    private func escape(_ app: XCUIApplication) {
        app.typeKey(.escape, modifierFlags: [])
    }

    func test1EscapeClosesAPanel() throws {
        let app = signedInApp()
        openSettings(app)
        escape(app)
        waitGone(element(app, "settingsSheet"), timeout: 10, "Escape closes the settings panel")
    }

    func test2EscapeClosesASheetWithFocusInATextFieldAndLeavesThePanelUnderneath() throws {
        let app = signedInApp()
        openVaultAddSheet(app)
        let name = element(app, "vaultNameField")
        waitFor(name, timeout: 5, "name field")
        name.hit()
        escape(app)
        waitGone(element(app, "vaultAddSheet"), timeout: 10, "Escape closes the sheet with focus in a text field")
        XCTAssertTrue(element(app, "settingsSheet").exists, "only the top popup closed")
        escape(app)
        waitGone(element(app, "settingsSheet"), timeout: 10, "a second Escape closes the panel underneath")
    }

    func test3EscapeClosesADialogOnTopOfAPanelAndLeavesThePanel() throws {
        let app = signedInApp()
        openSettings(app)
        let signOut = app.buttons["settingsSignOutRow"]
        waitFor(signOut, timeout: 10, "sign out row")
        signOut.hit()
        waitFor(element(app, "macDialog"), timeout: 10, "sign out confirmation")
        escape(app)
        waitGone(element(app, "macDialog"), timeout: 10, "Escape cancels the confirmation")
        XCTAssertTrue(element(app, "settingsSheet").exists, "the panel under the dialog stays open")
        XCTAssertTrue(app.buttons["settingsSignOutRow"].exists, "Escape was Cancel, the owner is still signed in")
    }

    func test4EscapeOnASheetWithTypedInputAsksToDiscardAndKeepsTheSheetUntilDiscard() throws {
        let app = signedInApp()
        openVaultAddSheet(app)
        let name = element(app, "vaultNameField")
        waitFor(name, timeout: 5, "name field")
        name.hit()
        name.typeText("Unsaved Login")

        escape(app)
        waitFor(element(app, "macDialog"), timeout: 10, "discard prompt")
        XCTAssertTrue(element(app, "vaultAddSheet").exists, "the sheet stays while the prompt is open")

        escape(app)
        waitGone(element(app, "macDialog"), timeout: 10, "Escape on the prompt keeps editing")
        XCTAssertTrue(element(app, "vaultAddSheet").exists, "Keep editing leaves the sheet open")

        escape(app)
        waitFor(element(app, "macDialog"), timeout: 10, "discard prompt again")
        element(app, "escapeDiscard").hit()
        waitGone(element(app, "vaultAddSheet"), timeout: 10, "Discard closes the sheet")
        XCTAssertTrue(element(app, "settingsSheet").exists, "the panel underneath stays open")
    }
}
#endif
