import HermesDesign
import XCTest

@MainActor
class SettingsE2ETestCase: E2ETestCase {
    override func setUp() async throws {
        let seed = ProcessInfo.processInfo.environment["HERMES_UITEST_SEED"] ?? ""
        try XCTSkipUnless(seed == "parity", "needs a gateway started with --seed parity and HERMES_UITEST_SEED=parity")
        try await super.setUp()
    }

    func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    func signedIn(arguments: [String] = [], resetCredentials: Bool = false) -> XCUIApplication {
        let app = launch(resetCredentials: resetCredentials, extraArguments: arguments)
        signInIfNeeded(app)
        return app
    }

    func openSettings(_ app: XCUIApplication) {
        let avatar = app.buttons["userAvatarButton"]
        waitFor(avatar, timeout: 30, "avatar button")
        avatar.tap()
        waitFor(element(app, "settingsSheet"), timeout: 15, "settings sheet")
    }

    func scrollTo(_ app: XCUIApplication, _ identifier: String, attempts: Int = 8) -> XCUIElement {
        let target = element(app, identifier)
        for _ in 0..<attempts {
            if target.exists, target.isHittable { return target }
            app.swipeUp()
        }
        waitFor(target, timeout: 5, identifier)
        return target
    }

    func openRow(_ app: XCUIApplication, _ identifier: String, screen: String) {
        let row = scrollTo(app, identifier)
        row.tap()
        waitFor(element(app, screen), timeout: 15, screen)
    }

    func goBack(_ app: XCUIApplication, from screen: String) {
        let back = app.buttons["\(screen)-back"]
        waitFor(back, timeout: 10, "\(screen) back")
        back.tap()
        waitFor(element(app, "settingsSheet"), timeout: 10, "settings sheet after back")
    }

    func relaunchSignedIn() -> XCUIApplication {
        XCUIApplication().terminate()
        return signedIn()
    }

    func settle(_ seconds: TimeInterval = 1.5) {
        Thread.sleep(forTimeInterval: seconds)
    }

    func acceptNotificationPermissionIfAsked() {
        let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        if alert.waitForExistence(timeout: 6) {
            let allow = alert.buttons["Allow"]
            if allow.exists { allow.tap() }
        }
    }
}

final class SettingsE2ETests: SettingsE2ETestCase {
    private static let hiddenRows = ["The X Subscription", "Delete Account", "Help Center", "Privacy Policy", "Terms of Service", "Hermes Bots Terms"]

    func test01RootShowsEveryRowAndHidesTheDroppedOnes() throws {
        let app = signedIn(resetCredentials: true)
        openSettings(app)
        for identifier in ["settingsAccountRow", "settingsUsageRow", "settingsVaultRow", "settingsPermissionsRow", "settingsTimeZoneAutoToggle", "settingsTimeZoneRow"] {
            waitFor(element(app, identifier), timeout: 15, identifier)
        }
        for identifier in ["settingsBotComputerRow", "settingsDevicesRow", "settingsImportMemoryRow", "settingsNotificationsToggle", "settingsAppearanceRow", "settingsLanguageRow", "settingsHapticsRow", "settingsDataSharingRow", "settingsFeedbackRow", "settingsSignOutRow"] {
            _ = scrollTo(app, identifier)
        }
        waitFor(element(app, "settingsVersion"), timeout: 5, "version footer")
        for text in Self.hiddenRows {
            XCTAssertFalse(app.staticTexts[text].exists, "\(text) must stay hidden")
            XCTAssertFalse(app.buttons[text].exists, "\(text) must stay hidden")
        }
        XCTAssertFalse(element(app, "settingsConnectAppsRow").exists, "no Connect apps route exists, so no row")
        shot(app, "settings-root-bottom")
    }

    func test02AppearanceChangeRethemesImmediatelyAndPersistsAcrossRelaunch() throws {
        var app = signedIn()
        openSettings(app)
        openRow(app, "settingsAppearanceRow", screen: "appearanceScreen")
        XCTAssertTrue(element(app, "appearanceMode-followSystem").isSelected, "follow system is the default")
        let before = XCUIScreen.main.screenshot()
        element(app, "appearanceMode-black").tap()
        settle()
        XCTAssertTrue(element(app, "appearanceMode-black").isSelected)
        XCTAssertFalse(element(app, "appearanceMode-followSystem").isSelected)
        XCTAssertNotEqual(before.pngRepresentation, XCUIScreen.main.screenshot().pngRepresentation, "the sheet re-themed at once")
        goBack(app, from: "appearanceScreen")
        XCTAssertTrue(app.buttons["settingsAppearanceRow"].label.contains("Black"), app.buttons["settingsAppearanceRow"].label)
        app = relaunchSignedIn()
        openSettings(app)
        openRow(app, "settingsAppearanceRow", screen: "appearanceScreen")
        XCTAssertTrue(element(app, "appearanceMode-black").isSelected, "black survived the relaunch")
        element(app, "appearanceMode-followSystem").tap()
        settle()
    }

    func test03TimeZoneAutomaticTogglePersistsOnTheGateway() throws {
        var app = signedIn()
        openSettings(app)
        let toggle = element(app, "settingsTimeZoneAutoToggle")
        waitFor(toggle, timeout: 20, "time zone toggle")
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.tap()
        let on = NSPredicate(format: "value == %@", "1")
        wait(for: [XCTNSPredicateExpectation(predicate: on, object: toggle)], timeout: 15)
        settle(2.5)
        app = relaunchSignedIn()
        openSettings(app)
        let reloaded = element(app, "settingsTimeZoneAutoToggle")
        waitFor(reloaded, timeout: 20, "time zone toggle after relaunch")
        wait(for: [XCTNSPredicateExpectation(predicate: on, object: reloaded)], timeout: 15)
        let zone = element(app, "settingsTimeZoneRow")
        XCTAssertFalse(zone.label.isEmpty, "the device zone is shown")
        XCTAssertFalse(zone.label.contains("_"), "underscores read as spaces: \(zone.label)")
    }

    func test04PerBotNotificationToggleAndPermissionPersist() throws {
        var app = signedIn()
        openSettings(app)
        let global = element(app, "settingsNotificationsToggle")
        _ = scrollTo(app, "settingsNotificationsToggle")
        if global.value as? String != "1" {
            global.tap()
            acceptNotificationPermissionIfAsked()
        }
        let on = NSPredicate(format: "value == %@", "1")
        wait(for: [XCTNSPredicateExpectation(predicate: on, object: global)], timeout: 15)
        openRow(app, "settingsBotNotificationsRow", screen: "botNotificationsScreen")
        let bot = element(app, "botNotifications-cho-ua")
        waitFor(bot, timeout: 30, "per bot toggle")
        XCTAssertEqual(bot.value as? String, "1", "notifications default to on")
        bot.tap()
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "0"), object: bot)], timeout: 15)
        settle(2)
        app = relaunchSignedIn()
        openSettings(app)
        openRow(app, "settingsBotNotificationsRow", screen: "botNotificationsScreen")
        let reloaded = element(app, "botNotifications-cho-ua")
        waitFor(reloaded, timeout: 30, "per bot toggle after relaunch")
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "0"), object: reloaded)], timeout: 20)
        XCTAssertEqual(element(app, "botNotifications-cho-dinh").value as? String, "1", "other bots are untouched")
        reloaded.tap()
        wait(for: [XCTNSPredicateExpectation(predicate: on, object: reloaded)], timeout: 15)
    }

    func test05PermissionsRuleAndAutoReviewPersist() throws {
        var app = signedIn()
        openSettings(app)
        openRow(app, "settingsPermissionsRow", screen: "permissionsScreen")
        let rule = "Never delete files outside the workspace"
        waitFor(element(app, "permissionsAddRule-ask"), timeout: 20, "add rule")
        XCTAssertTrue(element(app, "permissionsNoRules-ask").exists)
        element(app, "permissionsAddRule-ask").tap()
        let field = element(app, "permissionsRuleText")
        waitFor(field, timeout: 10, "rule field")
        field.tap()
        field.typeText(rule)
        element(app, "permissionsSaveRule").tap()
        let saved = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "permissionsRule-", rule)).firstMatch
        waitFor(saved, timeout: 20, "saved rule")
        let auto = element(app, "permissionsAutoReviewToggle")
        let wasOn = auto.value as? String == "1"
        auto.tap()
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", wasOn ? "0" : "1"), object: auto)], timeout: 15)
        settle(2)
        app = relaunchSignedIn()
        openSettings(app)
        let summary = app.buttons["settingsPermissionsRow"]
        waitFor(summary, timeout: 20, "permissions row")
        XCTAssertTrue(summary.label.contains("1 rule"), summary.label)
        XCTAssertTrue(summary.label.contains(wasOn ? "Auto-review off" : "Auto-review on"), summary.label)
        openRow(app, "settingsPermissionsRow", screen: "permissionsScreen")
        waitFor(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "permissionsRule-", rule)).firstMatch, timeout: 20, "rule after relaunch")
        shot(app, "permissions-after-relaunch")
    }

    func test06UsageRendersEverySeededSubscription() throws {
        let app = signedIn()
        openSettings(app)
        openRow(app, "settingsUsageRow", screen: "usageScreen")
        waitFor(element(app, "usageMeter-e2e-openai-codex/Weekly"), timeout: 45, "codex weekly meter")
        let weekly = element(app, "usageMeter-e2e-openai-codex/Weekly")
        XCTAssertEqual(weekly.label, "Weekly usage limit")
        XCTAssertTrue((weekly.value as? String ?? "").hasPrefix("42%"), "\(weekly.value ?? "nil")")
        XCTAssertTrue((weekly.value as? String ?? "").contains("Resets in 6 days"), "\(weekly.value ?? "nil")")
        XCTAssertTrue((element(app, "usageMeter-e2e-openai-codex/Session").value as? String ?? "").hasPrefix("18%"))
        waitFor(element(app, "usageMeter-e2e-copilot/Chat"), timeout: 10, "copilot chat meter")
        XCTAssertTrue((element(app, "usageMeter-e2e-copilot/Chat").value as? String ?? "").hasPrefix("60%"))
        XCTAssertTrue((element(app, "usageMeter-e2e-copilot/Completions").value as? String ?? "").hasPrefix("25%"))
        let spend = scrollTo(app, "usageSpend-e2e-openai-api")
        XCTAssertTrue(spend.label.contains("$4.27"), spend.label)
        XCTAssertTrue(element(app, "usageNoLimits-e2e-openai-api").exists, "an API key shows no limits")
        for account in ["e2e-openai-codex", "e2e-copilot", "e2e-openai-api"] {
            XCTAssertTrue(element(app, "usageCaption-\(account)").exists, account)
        }
        shot(app, "usage-all-subscriptions")
        goBack(app, from: "usageScreen")
        let usageRow = app.buttons["settingsUsageRow"]
        XCTAssertTrue(usageRow.label.contains("42%"), "root summarises the busiest window: \(usageRow.label)")
    }

    func test07VaultAddShowsNamesOnlyAndRemoveWorks() throws {
        let app = signedIn()
        openSettings(app)
        openRow(app, "settingsVaultRow", screen: "vaultScreen")
        waitFor(element(app, "vaultAddButton"), timeout: 20, "add button")
        element(app, "vaultAddButton").tap()
        waitFor(element(app, "vaultAddSheet"), timeout: 10, "add sheet")
        let secret = "correct-horse-battery-staple"
        func type(_ identifier: String, _ text: String) {
            let field = element(app, identifier)
            waitFor(field, timeout: 10, identifier)
            field.tap()
            field.typeText(text)
        }
        type("vaultNameField", "E2E Shop")
        type("vaultWebsiteField", "shop.example.com")
        type("vaultIdentifierField", "buyer@example.com")
        type("vaultPasswordField", secret)
        element(app, "vaultSaveButton").tap()
        let item = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "vaultItem-", "E2E Shop")).firstMatch
        waitFor(item, timeout: 30, "vault item")
        XCTAssertTrue(item.label.contains("buyer@example.com"), item.label)
        XCTAssertFalse(app.staticTexts[secret].exists, "the password never appears")
        XCTAssertFalse(XCUIApplication().debugDescription.contains(secret), "the password is not in the hierarchy")
        shot(app, "vault-with-item")
        item.tap()
        let remove = app.buttons["Remove"]
        waitFor(remove, timeout: 10, "remove confirmation")
        remove.tap()
        waitGone(item, timeout: 30, "vault item removed")
    }

    func test08BotComputerShowsDiskAndResetsAfterConfirming() throws {
        let app = signedIn()
        openSettings(app)
        openRow(app, "settingsBotComputerRow", screen: "botComputerScreen")
        let disk = element(app, "botComputerDisk")
        waitFor(disk, timeout: 20, "disk row")
        let known = ["Normal", "Low", "Almost full"]
        let deadline = Date().addingTimeInterval(20)
        while !known.contains(where: { disk.label.contains($0) }), Date() < deadline { settle(0.5) }
        XCTAssertTrue(known.contains(where: { disk.label.contains($0) }), disk.label)
        element(app, "botComputerResetRow").tap()
        let confirm = app.buttons["Reset Computer"].firstMatch
        waitFor(confirm, timeout: 10, "reset confirmation")
        app.sheets.buttons["Reset Computer"].firstMatch.tap()
        let footnote = element(app, "botComputerFootnote")
        let reset = NSPredicate(format: "label CONTAINS %@", "Computer reset")
        wait(for: [XCTNSPredicateExpectation(predicate: reset, object: footnote)], timeout: 30)
    }

    func test09DevicesMarkThisDeviceAndRemoveAnother() throws {
        let app = signedIn()
        openSettings(app)
        openRow(app, "settingsDevicesRow", screen: "devicesScreen")
        let mine = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "device-", "This device")).firstMatch
        waitFor(mine, timeout: 30, "this device row")
        XCTAssertTrue(mine.label.contains("iOS"), mine.label)
        let others = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND NOT label CONTAINS %@", "device-", "This device"))
        waitFor(others.firstMatch, timeout: 10, "other devices")
        XCTAssertGreaterThanOrEqual(others.count, 2)
        shot(app, "devices-list")
        let target = app.buttons["device-e2e-desktop-0002"]
        waitFor(target, timeout: 10, "tsnanh desktop")
        XCTAssertTrue(target.label.contains("Computer · Last opened"), target.label)
        target.tap()
        waitFor(element(app, "deviceDetailScreen"), timeout: 10, "device detail")
        element(app, "deviceRemoveRow").tap()
        let remove = app.buttons["Remove"]
        waitFor(remove, timeout: 10, "remove confirmation")
        remove.tap()
        waitFor(element(app, "devicesScreen"), timeout: 20, "back on the list")
        waitGone(app.buttons["device-e2e-desktop-0002"], timeout: 30, "removed device")
        XCTAssertTrue(app.buttons["device-e2e-desktop-0001"].exists, "the other device stays")
    }

    func test10ImportMemoryReportsWhatLanded() throws {
        let app = signedIn()
        openSettings(app)
        openRow(app, "settingsImportMemoryRow", screen: "importMemoryScreen")
        let editor = element(app, "importMemoryText")
        waitFor(editor, timeout: 10, "memory text")
        editor.tap()
        editor.typeText("Prefers morning meetings\nLives in Ho Chi Minh City\nPrefers morning meetings")
        element(app, "importMemoryButton").tap()
        let footnote = element(app, "importMemoryFootnote")
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Added 2 memories"), object: footnote)], timeout: 30)
        XCTAssertTrue(footnote.label.contains("1 already remembered"), footnote.label)
    }

    func test11DataSharingAndHapticsPersist() throws {
        var app = signedIn()
        openSettings(app)
        openRow(app, "settingsHapticsRow", screen: "hapticsScreen")
        let haptics = element(app, "hapticsToggle")
        waitFor(haptics, timeout: 10, "haptics toggle")
        XCTAssertEqual(haptics.value as? String, "1")
        haptics.tap()
        settle()
        goBack(app, from: "hapticsScreen")
        XCTAssertTrue(app.buttons["settingsHapticsRow"].label.contains("Off"), app.buttons["settingsHapticsRow"].label)
        openRow(app, "settingsDataSharingRow", screen: "dataSharingScreen")
        let enabled = element(app, "dataSharingEnabledToggle")
        waitFor(enabled, timeout: 20, "sharing toggle")
        let initial = enabled.value as? String ?? "0"
        enabled.tap()
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", initial == "1" ? "0" : "1"), object: enabled)], timeout: 15)
        settle(2)
        app = relaunchSignedIn()
        openSettings(app)
        XCTAssertTrue(app.buttons["settingsHapticsRow"].label.contains("Off"), "haptics preference survived")
        openRow(app, "settingsDataSharingRow", screen: "dataSharingScreen")
        let reloaded = element(app, "dataSharingEnabledToggle")
        waitFor(reloaded, timeout: 20, "sharing toggle after relaunch")
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", initial == "1" ? "0" : "1"), object: reloaded)], timeout: 15)
        reloaded.tap()
        goBack(app, from: "dataSharingScreen")
        openRow(app, "settingsHapticsRow", screen: "hapticsScreen")
        element(app, "hapticsToggle").tap()
    }

    func test12AccountShowsTheSignedInAccountAndGuardsSwitching() throws {
        let app = signedIn()
        openSettings(app)
        openRow(app, "settingsAccountRow", screen: "accountScreen")
        waitFor(element(app, "accountCurrentRow"), timeout: 10, "current account")
        waitFor(element(app, "accountSwitchCurrent"), timeout: 10, "switch list")
        XCTAssertFalse(app.staticTexts["Delete Account"].exists, "Delete Account stays hidden")
        element(app, "accountAddRow").tap()
        let cancel = app.buttons["Cancel"]
        waitFor(cancel, timeout: 10, "add account confirmation")
        cancel.tap()
        waitFor(element(app, "accountScreen"), timeout: 10, "still signed in")
    }

    func test13SignOutAsksFirstThenReturnsToSignIn() throws {
        let app = signedIn()
        openSettings(app)
        let signOut = scrollTo(app, "settingsSignOutRow")
        signOut.tap()
        let cancel = app.buttons["Cancel"]
        waitFor(cancel, timeout: 10, "sign out confirmation")
        cancel.tap()
        waitFor(element(app, "settingsSheet"), timeout: 10, "still in settings")
        signOut.tap()
        let confirm = app.sheets.buttons["Sign Out"].firstMatch
        waitFor(confirm, timeout: 10, "confirm sign out")
        confirm.tap()
        waitFor(app.buttons["signInButton"], timeout: 30, "sign in form")
    }
}
