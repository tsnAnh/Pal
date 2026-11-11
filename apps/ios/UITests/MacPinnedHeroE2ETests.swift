#if os(macOS)
import PalDesign
import XCTest

@MainActor
final class MacPinnedHeroE2ETests: BotProfileTestCase {
    private static let wanted = 2

    private func botButtons(in scope: XCUIElement) -> [XCUIElement] {
        scope.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "botRow-")).allElementsBoundByIndex
    }

    private func listRows(_ app: XCUIApplication) -> [XCUIElement] {
        let hero = element(app, "pinnedHero").frame
        return app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "botRow-")).allElementsBoundByIndex
            .filter { !$0.frame.intersects(hero) }
            .sorted { $0.frame.minY < $1.frame.minY }
    }

    private func slug(_ row: XCUIElement) -> String { String(row.identifier.dropFirst("botRow-".count)) }

    private func createBot(_ app: XCUIApplication, name: String) {
        app.typeKey("n", modifierFlags: .command)
        waitFor(element(app, "createBotSheet"), timeout: 15, "create bot modal")
        let field = element(app, "botNameField")
        field.hit()
        field.typeText(name)
        waitUntil(10, "create enables") { app.buttons["createBotConfirm"].isEnabled }
        app.buttons["createBotConfirm"].hit()
        waitGone(element(app, "createBotSheet"), timeout: 30, "modal closes after create")
        waitFor(element(app, "composerField"), timeout: 30, "composer of the new bot")
    }

    private func toggle(_ app: XCUIApplication, slug: String, item: String) {
        let row = app.buttons["botRow-\(slug)"]
        waitFor(row, timeout: 15, "row for \(slug)")
        row.rightClick()
        let entry = app.menuItems[item]
        waitFor(entry, timeout: 10, "\(item) in the context menu")
        entry.hit()
    }

    private func inHero(_ app: XCUIApplication, _ slug: String) -> XCUIElement {
        element(app, "pinnedHero").buttons["botRow-\(slug)"]
    }

    func test1PinnedBotsFillTheHeroAndLeaveTheList() throws {
        for mode in [AppearanceMode.dark, .light] {
            let app = launch(extraArguments: ["-\(AppearanceStore.defaultsKey)", mode.rawValue])
            app.activate()
            signInIfNeeded(app)
            app.activate()
            waitFor(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "botRow-")).firstMatch, timeout: 30, "roster rows")
            if element(app, "sidebarRail").exists {
                app.typeKey("b", modifierFlags: .command)
                waitFor(element(app, "sidebarExpanded"), timeout: 10, "expanded sidebar")
            }
            waitFor(element(app, "pinnedHero"), timeout: 10, "hero")

            var created = 0
            while listRows(app).count < Self.wanted {
                created += 1
                createBot(app, name: "Pinscout \(mode.rawValue) \(created) \(Int.random(in: 1000...9999))")
                Thread.sleep(forTimeInterval: 1)
            }

            let targets = listRows(app).prefix(Self.wanted).map(slug)
            XCTAssertEqual(targets.count, Self.wanted)
            for target in targets {
                toggle(app, slug: target, item: "pinAction")
                waitFor(inHero(app, target), timeout: 20, "\(target) pinned into the hero")
            }
            for target in targets {
                XCTAssertEqual(app.buttons.matching(identifier: "botRow-\(target)").count, 1, "\(target) appears once, in the hero only")
            }

            let hero = element(app, "pinnedHero")
            let sidebar = element(app, "sidebarExpanded")
            XCTAssertGreaterThanOrEqual(hero.frame.minX, sidebar.frame.minX - 0.5, "hero stays inside the sidebar")
            XCTAssertLessThanOrEqual(hero.frame.maxX, sidebar.frame.maxX + 0.5, "hero stays inside the sidebar")
            for tile in botButtons(in: hero) {
                XCTAssertGreaterThanOrEqual(tile.frame.minX, sidebar.frame.minX)
                XCTAssertLessThanOrEqual(tile.frame.maxX, sidebar.frame.maxX)
            }
            Thread.sleep(forTimeInterval: 0.8)
            shot(app, "mac-pinned-hero-\(mode.rawValue)")

            for target in targets {
                toggle(app, slug: target, item: "unpinAction")
                waitGone(inHero(app, target), timeout: 20, "\(target) leaves the hero")
                waitFor(app.buttons["botRow-\(target)"], timeout: 20, "\(target) back in the list")
                XCTAssertFalse(inHero(app, target).exists)
            }
            app.terminate()
        }
    }
}
#endif
