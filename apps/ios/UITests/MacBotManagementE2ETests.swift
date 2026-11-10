#if os(macOS)
import AppKit
import HermesDesign
import XCTest

@MainActor
final class MacBotManagementE2ETests: BotProfileTestCase {
    private static let sandboxOtherSlug = "bot-alpha"

    private func openExpandedSidebar() -> XCUIApplication {
        let app = signedInApp()
        app.activate()
        if element(app, "sidebarRail").exists {
            app.typeKey("b", modifierFlags: .command)
            waitFor(element(app, "sidebarExpanded"), timeout: 10, "expanded sidebar")
        }
        return app
    }

    private func createBot(_ app: XCUIApplication) -> String {
        let name = "mgmt\(Int.random(in: 10000...99999))"
        app.typeKey("n", modifierFlags: .command)
        waitFor(element(app, "createBotSheet"), timeout: 15, "create bot modal")
        let field = element(app, "botNameField")
        field.hit()
        field.typeText(name)
        waitUntil(10, "create enables") { app.buttons["createBotConfirm"].isEnabled }
        app.buttons["createBotConfirm"].hit()
        waitGone(element(app, "createBotSheet"), timeout: 30, "modal closes after create")
        waitFor(element(app, "composerField"), timeout: 30, "composer of the new bot")
        return name
    }

    private func choose(_ app: XCUIApplication, slug: String, item: String) {
        let row = app.buttons["botRow-\(slug)"]
        waitFor(row, timeout: 20, "row for \(slug)")
        row.rightClick()
        let entry = app.menuItems[item]
        waitFor(entry, timeout: 10, "\(item) in the context menu")
        entry.hit()
    }

    private func menuHas(_ app: XCUIApplication, slug: String, item: String) -> Bool {
        let row = app.buttons["botRow-\(slug)"]
        row.rightClick()
        let exists = app.menuItems[item].waitForExistence(timeout: 5)
        app.typeKey(.escape, modifierFlags: [])
        return exists
    }

    private func openOther(_ app: XCUIApplication) {
        let other = app.buttons["botRow-\(Self.sandboxOtherSlug)"]
        waitFor(other, timeout: 20, "another bot row")
        other.hit()
        waitFor(element(app, "composerField"), timeout: 20, "other bot chat")
    }

    private func deleteBot(_ app: XCUIApplication, slug: String) {
        choose(app, slug: slug, item: "deleteBotAction")
        let confirm = app.buttons["deleteBotConfirm"]
        let dialogConfirm = app.sheets.buttons["Delete"]
        waitUntil(10, "delete confirmation appears") { confirm.exists || dialogConfirm.exists }
        (confirm.exists ? confirm : dialogConfirm).hit()
        waitUntil(30, "deleted bot leaves the sidebar") { !app.buttons["botRow-\(slug)"].exists }
    }

    func test1HidingMovesABotIntoHiddenBotsAndShowingBringsItBack() throws {
        let app = openExpandedSidebar()
        let slug = createBot(app)
        openOther(app)

        choose(app, slug: slug, item: "hideBotAction")
        let hiddenRow = element(app, "hiddenBotsList").buttons["botRow-\(slug)"]
        waitUntil(20, "hidden bot leaves the list") { !app.buttons["botRow-\(slug)"].exists || hiddenRow.exists }
        let header = app.buttons["hiddenBotsHeader"]
        waitFor(header, timeout: 20, "Hidden Bots header")
        XCTAssertEqual(header.value as? String, "1")
        if !hiddenRow.exists { header.hit() }
        waitFor(hiddenRow, timeout: 10, "hidden bot inside the section")
        shot(app, "mac-hidden-bots-expanded")

        XCTAssertTrue(menuHas(app, slug: slug, item: "showBotAction"))
        choose(app, slug: slug, item: "showBotAction")
        waitUntil(20, "shown bot returns to the list") { app.buttons["botRow-\(slug)"].exists && !self.element(app, "hiddenBotsList").buttons["botRow-\(slug)"].exists }
        waitGone(header, timeout: 20, "Hidden Bots section disappears when empty")
        deleteBot(app, slug: slug)
        app.terminate()
    }

    func test2RenamingChangesTheBotNameEverywhere() throws {
        let app = openExpandedSidebar()
        let slug = createBot(app)
        openOther(app)

        choose(app, slug: slug, item: "renameBotAction")
        waitFor(element(app, "renameBotSheet"), timeout: 10, "rename panel")
        let field = element(app, "renameBotField")
        waitFor(field, timeout: 10, "rename field")
        XCTAssertFalse(app.buttons["renameBotSave"].isEnabled, "unchanged name cannot be saved")
        field.hit()
        app.typeKey("a", modifierFlags: .command)
        let renamed = "Renamed \(Int.random(in: 100...999))"
        field.typeText(renamed)
        waitUntil(5, "save enables") { app.buttons["renameBotSave"].isEnabled }
        shot(app, "mac-rename-bot")
        app.buttons["renameBotSave"].hit()
        waitGone(element(app, "renameBotSheet"), timeout: 20, "rename panel closes")
        waitUntil(30, "row shows the new name") { app.buttons["botRow-\(slug)"].label.contains(renamed) }
        openOther(app)
        deleteBot(app, slug: slug)
        app.terminate()
    }

    func test3DeletingAsksForConfirmationAndRemovesTheBot() throws {
        let app = openExpandedSidebar()
        let slug = createBot(app)
        openOther(app)

        choose(app, slug: slug, item: "deleteBotAction")
        let confirm = app.buttons["deleteBotConfirm"]
        let dialogConfirm = app.sheets.buttons["Delete"]
        waitUntil(10, "delete confirmation appears") { confirm.exists || dialogConfirm.exists }
        shot(app, "mac-delete-confirm")
        let cancel = app.sheets.buttons["Cancel"].exists ? app.sheets.buttons["Cancel"] : app.buttons["Cancel"]
        cancel.hit()
        XCTAssertTrue(app.buttons["botRow-\(slug)"].exists, "cancelling keeps the bot")

        choose(app, slug: slug, item: "deleteBotAction")
        waitUntil(10, "delete confirmation appears again") { confirm.exists || dialogConfirm.exists }
        (confirm.exists ? confirm : dialogConfirm).hit()
        waitUntil(30, "deleted bot leaves the sidebar") { !app.buttons["botRow-\(slug)"].exists }
        XCTAssertFalse(menuHas(app, slug: Self.primarySlug, item: "deleteBotAction"), "the primary bot cannot be deleted")
        app.terminate()
    }

    func test4MarkAsUnreadShowsTheDotUntilTheBotIsOpened() throws {
        let app = openExpandedSidebar()
        let slug = createBot(app)
        openOther(app)

        choose(app, slug: slug, item: "markUnreadAction")
        waitUntil(10, "row reads unread") { app.buttons["botRow-\(slug)"].label.contains("unread") }
        XCTAssertTrue(menuHas(app, slug: slug, item: "markReadAction"))

        app.terminate()
        let relaunched = openExpandedSidebar()
        waitUntil(20, "unread survives a relaunch") { relaunched.buttons["botRow-\(slug)"].label.contains("unread") }
        shot(relaunched, "mac-unread-dot")

        relaunched.buttons["botRow-\(slug)"].hit()
        waitFor(element(relaunched, "composerField"), timeout: 20, "opened chat")
        waitUntil(10, "opening clears the unread mark") { !relaunched.buttons["botRow-\(slug)"].label.contains("unread") }
        openOther(relaunched)
        deleteBot(relaunched, slug: slug)
        relaunched.terminate()
    }

    func test5CopyConversationIDPutsTheSessionIDOnThePasteboard() throws {
        let app = openExpandedSidebar()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        choose(app, slug: Self.sandboxOtherSlug, item: "copyConversationIDAction")
        waitUntil(10, "pasteboard receives the conversation id") { !(pasteboard.string(forType: .string) ?? "").isEmpty }
        let copied = pasteboard.string(forType: .string) ?? ""
        XCTAssertNotEqual(copied, Self.sandboxOtherSlug, "the id is the session id, not the bot name")
        XCTAssertFalse(copied.contains(" "))
        app.terminate()
    }

    func test6UsageBannerStaysHiddenWhileUsageIsBelowTheThreshold() throws {
        let app = openExpandedSidebar()
        openOther(app)
        app.buttons["userAvatarButton"].hit()
        let usage = app.buttons["accountMenuUsage"]
        waitFor(usage, timeout: 15, "usage entry in the account menu")
        let headlineLoaded = NSPredicate(format: "label CONTAINS %@", "%")
        _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: headlineLoaded, object: usage)], timeout: 15)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(element(app, "usageBanner").waitForExistence(timeout: 5), "usage under 75% or unavailable shows no banner")
        app.terminate()
    }
}
#endif
