import XCTest

@MainActor
final class DiagnosticsE2ETests: BotProfileTestCase {
    func testAFailedCallAppearsInDiagnosticsWithDetailsAndClearEmptiesIt() throws {
        let app = signedInApp(
            connectedServices: ["slack"], extraArguments: ["-hermes-test-chat-install", "-hermes-test-chat-install-fail"]
        )
        openProfile(app, Self.primarySlug)
        element(app, "profileSlackRow").tap()
        waitFor(element(app, "chatInstallStatus"), timeout: 30, "the failing call shows its status")
        app.terminate()
        app.launch()
        openDiagnostics(app)
        let row = element(app, "diagnosticsRow").firstMatch
        waitFor(row, timeout: 15, "the failed call is listed")
        waitFor(app.staticTexts["Only the owner can do this."].firstMatch, timeout: 5, "the reason in plain words")
        XCTAssertTrue(element(app, "diagnosticsTrace").firstMatch.label.contains("trace 7f3k2m9a"), "the row names the trace")
        XCTAssertFalse(element(app, "diagnosticsCopy").exists, "details start collapsed")
        element(app, "diagnosticsDetails").firstMatch.hit()
        waitFor(element(app, "diagnosticsCopy").firstMatch, timeout: 10, "details offer Copy")
        clear(app)
        waitFor(element(app, "diagnosticsEmpty"), timeout: 10, "the empty state after Clear")
        XCTAssertFalse(element(app, "diagnosticsRow").exists, "Clear empties the list")
    }

    private func openDiagnostics(_ app: XCUIApplication) {
        #if os(macOS)
        app.typeKey(",", modifierFlags: .command)
        waitFor(element(app, "settingsSheet"), timeout: 15, "settings")
        app.buttons["macSettingsSection-diagnostics"].hit()
        waitFor(element(app, "macSettingsPage-diagnostics"), timeout: 10, "diagnostics page")
        #else
        let avatar = app.buttons["userAvatarButton"]
        waitFor(avatar, timeout: 30, "avatar button")
        avatar.tap()
        waitFor(element(app, "settingsSheet"), timeout: 15, "settings")
        let entry = element(app, "settingsDiagnosticsRow")
        for _ in 0..<8 where !(entry.exists && entry.isHittable) { app.swipeUp() }
        entry.tap()
        waitFor(element(app, "diagnosticsScreen"), timeout: 10, "diagnostics screen")
        #endif
    }

    private func clear(_ app: XCUIApplication) {
        #if os(iOS)
        element(app, "diagnosticsActions").tap()
        #endif
        element(app, "diagnosticsClear").firstMatch.hit()
        waitFor(element(app, "diagnosticsClearConfirm").firstMatch, timeout: 10, "clear confirmation")
        element(app, "diagnosticsClearConfirm").firstMatch.hit()
    }
}
