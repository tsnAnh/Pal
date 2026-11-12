#if os(macOS)
import PalDesign
import XCTest

@MainActor
final class MacModalsE2ETests: BotProfileTestCase {
    private static let sections: [(id: String, title: String)] = [
        ("general", "General"), ("computer", "Computer"), ("permissions", "Permissions"),
        ("vault", "Vault"), ("usage", "Usage & Billing"), ("updates", "Updates"),
    ]

    private func openSettings(_ app: XCUIApplication) {
        app.typeKey(",", modifierFlags: .command)
        waitFor(element(app, "settingsSheet"), timeout: 15, "settings modal")
    }

    private func select(_ app: XCUIApplication, section: (id: String, title: String)) {
        let row = app.buttons["macSettingsSection-\(section.id)"]
        waitFor(row, timeout: 10, "\(section.title) in the section list")
        row.hit()
        let title = app.staticTexts["macSettingsTitle"]
        waitFor(title, timeout: 10, "\(section.title) title")
        waitUntil(10, "title reads \(section.title)") { title.exists && title.label == section.title }
        waitFor(element(app, "macSettingsPage-\(section.id)"), timeout: 10, "\(section.title) page")
    }

    private func closeModal(_ app: XCUIApplication, _ identifier: String, gone: String) {
        app.buttons[identifier].hit()
        waitGone(element(app, gone), timeout: 10, "\(gone) closes")
    }

    func test1CommandCommaOpensSettingsAndEverySectionIsReachable() throws {
        let app = signedInApp()
        openSettings(app)
        for section in Self.sections { select(app, section: section) }
        select(app, section: Self.sections[0])
        waitFor(element(app, "settingsAccountRow"), timeout: 10, "account row")
        waitFor(app.buttons["settingsSignOutRow"], timeout: 10, "sign out button")
        select(app, section: Self.sections[5])
        XCTAssertFalse(app.buttons["updatesCheckButton"].isEnabled, "no update flow exists yet")
        closeModal(app, "settingsClose", gone: "settingsSheet")
    }

    func test2VaultTabsFilterTheList() throws {
        let app = signedInApp()
        openSettings(app)
        select(app, section: Self.sections[3])
        waitFor(app.buttons["vaultAddButton"], timeout: 10, "new item button")
        app.buttons["vaultAddButton"].hit()
        waitFor(element(app, "vaultAddSheet"), timeout: 10, "add sheet")
        let name = "Mac Vault Login"
        for (identifier, text) in [("vaultNameField", name), ("vaultWebsiteField", "https://example.com"), ("vaultIdentifierField", "mac@example.com")] {
            let field = element(app, identifier)
            waitFor(field, timeout: 5, identifier)
            field.hit()
            field.typeText(text)
        }
        let password = element(app, "vaultPasswordField")
        password.hit()
        password.typeText("hunter2-mac")
        element(app, "vaultSaveButton").hit()
        let item = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "vaultRemove-")).firstMatch
        waitFor(item, timeout: 20, "saved login in the list")

        let all = app.buttons["macVaultTab-all"]
        let logins = app.buttons["macVaultTab-logins"]
        let payments = app.buttons["macVaultTab-payments"]
        XCTAssertTrue(all.label.hasPrefix("All "), all.label)
        XCTAssertFalse(logins.label.hasSuffix(" 0"), "the saved login is counted: \(logins.label)")
        XCTAssertTrue(payments.label.hasSuffix(" 0"), payments.label)

        payments.hit()
        waitFor(element(app, "vaultEmptyRow"), timeout: 10, "payments tab is empty")
        XCTAssertFalse(item.exists, "the login is filtered out of Payments")
        logins.hit()
        waitFor(item, timeout: 10, "logins tab lists the login")
        XCTAssertFalse(element(app, "vaultEmptyRow").exists)
        let search = element(app, "vaultSearchField")
        search.hit()
        search.typeText("zzz-no-match")
        waitFor(element(app, "vaultEmptyRow"), timeout: 10, "search narrows the list")
        closeModal(app, "settingsClose", gone: "settingsSheet")
    }

    func test3CommandNCreatesAndSelectsABot() throws {
        let app = signedInApp()
        app.typeKey("n", modifierFlags: .command)
        waitFor(element(app, "createBotSheet"), timeout: 15, "create bot modal")
        waitFor(element(app, "createBotPreview"), timeout: 10, "live avatar preview")
        XCTAssertFalse(app.buttons["createBotConfirm"].isEnabled, "an empty name cannot be created")
        let shapes = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "botShape-"))
        XCTAssertGreaterThanOrEqual(shapes.count, 13, "every avatar shape is offered")
        let swatches = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "botSwatch-"))
        XCTAssertGreaterThanOrEqual(swatches.count, 11)
        shapes.element(boundBy: 3).hit()
        swatches.element(boundBy: 7).hit()
        let field = element(app, "botNameField")
        field.hit()
        let name = "Macscout\(Int.random(in: 1000...9999))"
        field.typeText(name)
        waitUntil(10, "create enables") { app.buttons["createBotConfirm"].isEnabled }
        app.buttons["createBotConfirm"].hit()
        waitGone(element(app, "createBotSheet"), timeout: 30, "modal closes after create")
        let title = element(app, "chatTitle")
        waitFor(title, timeout: 30, "chat title")
        waitUntil(30, "new bot is selected") { title.exists && title.label.localizedCaseInsensitiveContains(name) }
        waitFor(element(app, "composerField"), timeout: 20, "composer of the new bot")
    }

    func test4CommandKFindsABotAndReturnOpensIt() throws {
        let app = signedInApp()
        openBot(app, "bot-alpha")
        app.typeKey("k", modifierFlags: .command)
        waitFor(element(app, "searchScreen"), timeout: 10, "palette")
        let field = element(app, "searchField")
        waitFor(field, timeout: 10, "palette field")
        field.typeText("Beta")
        waitFor(element(app, "searchResult-bot-bot-beta"), timeout: 20, "Bot Beta result")
        app.typeKey(.return, modifierFlags: [])
        waitGone(element(app, "searchScreen"), timeout: 10, "palette closes")
        let title = element(app, "chatTitle")
        waitUntil(20, "Return opens Bot Beta") { title.exists && title.label.contains("Beta") }

        app.typeKey("f", modifierFlags: [.command, .shift])
        waitFor(element(app, "searchScreen"), timeout: 10, "palette from shift-command-F")
        app.typeKey(.escape, modifierFlags: [])
        waitGone(element(app, "searchScreen"), timeout: 10, "Escape closes the palette")
    }

    func test5ShiftCommandMOpensConnectAppsAndChipsFilter() throws {
        let app = signedInApp()
        app.typeKey("m", modifierFlags: [.command, .shift])
        waitFor(element(app, "connectApps"), timeout: 15, "connect apps modal")
        waitFor(app.buttons["connectAppsChips-all"], timeout: 30, "All chip")
        waitFor(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "connectApp-")).firstMatch, timeout: 30, "catalog rows in All")
        XCTAssertFalse(element(app, "connectAppsSection-iphone").exists, "no device section")
        waitFor(app.buttons["connectedCountButton"], timeout: 10, "connected count")
        let category = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND NOT identifier ENDSWITH %@ AND NOT identifier ENDSWITH %@", "connectAppsChips-", "-all", "-iphone")).firstMatch
        waitFor(category, timeout: 30, "a catalog category chip")
        let categoryID = category.identifier.replacingOccurrences(of: "connectAppsChips-", with: "")
        category.hit()
        let heading = element(app, "connectAppsSectionTitle")
        waitFor(heading, timeout: 15, "category heading")
        XCTAssertEqual(heading.label, categoryID)
        XCTAssertFalse(element(app, "connectAppsSection-iphone").exists, "the category chip narrows the list")
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@ AND NOT identifier ENDSWITH %@", "connectApp-", "-action"))
        waitFor(rows.firstMatch, timeout: 20, "rows in \(categoryID)")
        closeModal(app, "connectApps-close", gone: "connectApps")
    }

    func test6AccountMenuOpensSettingsAndUsage() throws {
        let app = signedInApp()
        app.buttons["userAvatarButton"].hit()
        waitFor(element(app, "accountMenu"), timeout: 10, "account menu")
        for id in ["accountMenuUsage", "accountMenuSettings", "accountMenuAdd", "accountMenuLogout"] {
            waitFor(app.buttons[id], timeout: 5, id)
        }
        app.buttons["accountMenuUsage"].hit()
        waitFor(element(app, "settingsSheet"), timeout: 10, "settings from the account menu")
        let title = app.staticTexts["macSettingsTitle"]
        waitUntil(10, "usage section is open") { title.exists && title.label == "Usage & Billing" }
    }

    func test7WindowShotsInBothAppearances() throws {
        for mode in [AppearanceMode.dark, .light] {
            let suffix = mode.rawValue
            let app = launch(extraArguments: ["-\(AppearanceStore.defaultsKey)", mode.rawValue])
            signInIfNeeded(app)
            openBot(app, "bot-beta")
            send(app, "hello glass")
            waitFor(bubbles(app, "assistantBubble", containing: "stub-").firstMatch, timeout: 60, "reply")
            Thread.sleep(forTimeInterval: 1)
            shot(app, "mac-glass-main-\(suffix)")

            openSettings(app)
            for section in Self.sections {
                select(app, section: section)
                Thread.sleep(forTimeInterval: 1.2)
                shot(app, "mac-settings-\(section.id)-\(suffix)")
            }
            closeModal(app, "settingsClose", gone: "settingsSheet")

            app.typeKey("m", modifierFlags: [.command, .shift])
            waitFor(element(app, "connectApps"), timeout: 15, "connect apps")
            waitFor(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "connectApp-")).firstMatch, timeout: 30, "sections")
            Thread.sleep(forTimeInterval: 2)
            shot(app, "mac-connect-apps-\(suffix)")
            closeModal(app, "connectApps-close", gone: "connectApps")

            app.typeKey("n", modifierFlags: .command)
            waitFor(element(app, "createBotSheet"), timeout: 15, "create bot")
            Thread.sleep(forTimeInterval: 1)
            shot(app, "mac-create-bot-empty-\(suffix)")
            let field = element(app, "botNameField")
            field.hit()
            field.typeText("Pal Scout")
            Thread.sleep(forTimeInterval: 1.5)
            shot(app, "mac-create-bot-\(suffix)")
            app.buttons["createBotCancel"].hit()
            waitGone(element(app, "createBotSheet"), timeout: 10, "create bot closed")

            app.typeKey("k", modifierFlags: .command)
            waitFor(element(app, "searchScreen"), timeout: 10, "palette")
            Thread.sleep(forTimeInterval: 1.2)
            shot(app, "mac-palette-\(suffix)")
            app.typeKey(.escape, modifierFlags: [])
            waitGone(element(app, "searchScreen"), timeout: 10, "palette closed")

            app.buttons["userAvatarButton"].hit()
            waitFor(element(app, "accountMenu"), timeout: 10, "account menu")
            Thread.sleep(forTimeInterval: 0.8)
            shot(app, "mac-account-menu-\(suffix)")
            app.typeKey(.escape, modifierFlags: [])
            waitGone(element(app, "accountMenu"), timeout: 10, "account menu closed")
            app.terminate()
        }
    }
}
#endif
