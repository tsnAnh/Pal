#if os(macOS)
import PalDesign
import XCTest

@MainActor
final class MacShellE2ETests: BotProfileTestCase {
    private func rail(_ app: XCUIApplication) -> XCUIElement { element(app, "sidebarRail") }
    private func expandedSidebar(_ app: XCUIApplication) -> XCUIElement { element(app, "sidebarExpanded") }

    private func botRows(_ app: XCUIApplication) -> [XCUIElement] {
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "botRow-")).allElementsBoundByIndex
        return rows.sorted { $0.frame.minY < $1.frame.minY }
    }

    private func ensureExpandedSidebar(_ app: XCUIApplication) {
        if rail(app).exists {
            app.typeKey("b", modifierFlags: .command)
            waitFor(expandedSidebar(app), timeout: 10, "expanded sidebar")
        }
    }

    func test1CompactSidebarTogglesWithCommandBAndPersistsAfterRelaunch() throws {
        var app = signedInApp()
        ensureExpandedSidebar(app)
        app.typeKey("b", modifierFlags: .command)
        waitFor(rail(app), timeout: 10, "compact rail after Command-B")
        waitGone(expandedSidebar(app), timeout: 10, "expanded sidebar hidden")
        XCTAssertLessThanOrEqual(rail(app).frame.width, 80, "the rail is avatar-only")

        app.terminate()
        app = launch(extraArguments: ["-\(AppearanceStore.defaultsKey)", AppearanceMode.dark.rawValue])
        signInIfNeeded(app)
        waitFor(rail(app), timeout: 20, "compact rail after relaunch")
        XCTAssertFalse(expandedSidebar(app).exists)

        app.typeKey("b", modifierFlags: .command)
        waitFor(expandedSidebar(app), timeout: 10, "expanded sidebar restored")
        waitGone(rail(app), timeout: 10, "rail hidden after expanding")
    }

    func test2DetailsShortcutOpensInspectorWithNameAndRoutines() throws {
        let app = signedInApp()
        ensureExpandedSidebar(app)
        openBot(app, "bot-alpha")
        XCTAssertFalse(element(app, "botProfileScreen").exists)
        app.typeKey("i", modifierFlags: [.command, .shift])
        waitFor(element(app, "botProfileScreen"), timeout: 15, "inspector")
        let name = element(app, "profileName")
        waitFor(name, timeout: 15, "inspector name")
        XCTAssertTrue(name.label.contains("Bot Alpha"), name.label)
        waitFor(element(app, "inspectorRoutines"), timeout: 15, "routines section")
        waitFor(element(app, "inspectorTab-library"), timeout: 5, "library tab")
        app.typeKey("i", modifierFlags: [.command, .shift])
        waitGone(element(app, "botProfileScreen"), timeout: 10, "inspector closes with the same shortcut")
        app.typeKey("i", modifierFlags: [.command, .shift])
        waitFor(element(app, "inspectorClose"), timeout: 10, "close button")
        element(app, "inspectorClose").hit()
        waitGone(element(app, "botProfileScreen"), timeout: 10, "inspector closes with its button")
    }

    func test3CommandNumberSelectsThatBot() throws {
        let app = signedInApp()
        ensureExpandedSidebar(app)
        let rows = botRows(app)
        XCTAssertGreaterThanOrEqual(rows.count, 2, "the sandbox roster has at least two bots")
        let second = rows[1].label.components(separatedBy: ",").first ?? ""
        app.typeKey("2", modifierFlags: .command)
        let title = element(app, "chatTitle")
        waitFor(title, timeout: 20, "chat title after Command-2")
        XCTAssertEqual(title.label, second)
        let first = rows[0].label.components(separatedBy: ",").first ?? ""
        app.typeKey("1", modifierFlags: .command)
        waitUntil(10, "Command-1 selects the first bot") { title.exists && title.label == first }
        app.typeKey(.downArrow, modifierFlags: .option)
        waitUntil(10, "Option-Down selects the next bot") { title.exists && title.label == second }
    }

    func test4ShortcutsSheetOpensWithSlashAndCloses() throws {
        let app = signedInApp()
        app.typeKey("/", modifierFlags: .command)
        waitFor(element(app, "shortcutsSheet"), timeout: 10, "shortcuts sheet")
        waitFor(app.staticTexts["Keyboard shortcuts"], timeout: 5, "sheet title")
        waitFor(element(app, "shortcut-compactSidebar"), timeout: 5, "compact sidebar row")
        app.buttons["shortcutsClose"].hit()
        waitGone(element(app, "shortcutsSheet"), timeout: 10, "sheet closes")
    }

    func test5ReturnSendsAndShiftReturnInsertsNewline() throws {
        let app = signedInApp()
        openBot(app, "bot-beta")
        let field = element(app, "composerField")
        field.hit()
        field.typeText("line one")
        app.typeKey(.return, modifierFlags: .shift)
        field.typeText("line two")
        XCTAssertTrue((field.value as? String ?? "").contains("\n"), "shift-return inserts a newline")
        app.typeKey(.return, modifierFlags: [])
        waitFor(bubbles(app, "userBubble", containing: "line one").firstMatch, timeout: 15, "return sends")
    }

    func test6WindowShotsInBothAppearances() throws {
        for mode in [AppearanceMode.dark, .light] {
            let suffix = mode.rawValue
            let app = launch(extraArguments: ["-\(AppearanceStore.defaultsKey)", mode.rawValue])
            signInIfNeeded(app)
            ensureExpandedSidebar(app)
            openBot(app, "bot-beta")
            send(app, "hello beta")
            waitFor(bubbles(app, "assistantBubble", containing: "stub-").firstMatch, timeout: 60, "reply")
            Thread.sleep(forTimeInterval: 1)
            shot(app, "mac-main-\(suffix)")

            app.typeKey("i", modifierFlags: [.command, .shift])
            waitFor(element(app, "botProfileScreen"), timeout: 15, "inspector")
            waitFor(element(app, "inspectorRoutines"), timeout: 15, "routines")
            Thread.sleep(forTimeInterval: 1.5)
            shot(app, "mac-inspector-\(suffix)")
            element(app, "inspectorTab-library").hit()
            waitFor(element(app, "libraryScreen"), timeout: 15, "library tab")
            Thread.sleep(forTimeInterval: 1.5)
            shot(app, "mac-inspector-library-\(suffix)")
            app.typeKey("i", modifierFlags: [.command, .shift])
            waitGone(element(app, "botProfileScreen"), timeout: 10, "inspector closed")

            app.typeKey("b", modifierFlags: .command)
            waitFor(rail(app), timeout: 10, "rail")
            Thread.sleep(forTimeInterval: 0.6)
            shot(app, "mac-compact-\(suffix)")
            app.typeKey("b", modifierFlags: .command)
            waitFor(expandedSidebar(app), timeout: 10, "sidebar restored")

            app.typeKey("/", modifierFlags: .command)
            waitFor(element(app, "shortcutsSheet"), timeout: 10, "shortcuts")
            Thread.sleep(forTimeInterval: 0.6)
            shot(app, "mac-shortcuts-\(suffix)")
            app.buttons["shortcutsClose"].hit()
            waitGone(element(app, "shortcutsSheet"), timeout: 10, "sheet closed")
            app.terminate()
        }
    }

    func test7InspectorLibraryOffersFiltersAndGroupedEntries() throws {
        for mode in [AppearanceMode.dark, .light] {
            let suffix = mode.rawValue
            let app = launch(extraArguments: ["-\(AppearanceStore.defaultsKey)", mode.rawValue])
            signInIfNeeded(app)
            ensureExpandedSidebar(app)
            openBot(app, "bot-beta")
            let linkMessage = "links https://example.com/guide and https://www.apple.com/swift \(suffix)"
            send(app, linkMessage)
            waitForReply(app, below: "links https://example.com/guide", timeout: 90)
            app.typeKey("i", modifierFlags: [.command, .shift])
            waitFor(element(app, "botProfileScreen"), timeout: 15, "inspector")
            element(app, "inspectorTab-library").hit()
            waitFor(element(app, "libraryFilter-all"), timeout: 15, "All chip")
            waitFor(element(app, "libraryFilter-media"), timeout: 5, "Media chip")
            waitFor(element(app, "libraryFilter-files"), timeout: 5, "Files chip")
            XCTAssertFalse(element(app, "libraryFilter-links").exists, "the Mac inspector offers All, Media and Files")
            let today = element(app, "libraryCard-today")
            let older = element(app, "libraryCard-older")
            let empty = element(app, "libraryEmpty")
            waitUntil(60, "library settles into groups or the empty state") { today.exists || older.exists || empty.exists }
            Thread.sleep(forTimeInterval: 1.5)
            shot(app, "mac-inspector-library-groups-\(suffix)")
            app.terminate()
        }
    }
}
#endif
