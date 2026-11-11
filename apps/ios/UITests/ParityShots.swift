import PalDesign
import XCTest

@MainActor
final class ParityShots: E2ETestCase {
    private static let settleDelay: TimeInterval = 2

    private func signedInRoster() -> XCUIApplication {
        let app = launch(extraArguments: ["-\(AppearanceStore.defaultsKey)", AppearanceMode.dark.rawValue])
        signInIfNeeded(app)
        let anyBotRow = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "botRow-")).firstMatch
        waitFor(anyBotRow, timeout: 30, "roster rows")
        return app
    }

    private func parityShot(_ referenceName: String) {
        Thread.sleep(forTimeInterval: Self.settleDelay)
        screenShot("parity-\(referenceName)")
    }

    func test01Home() throws {
        let app = signedInRoster()
        waitFor(app.descendants(matching: .any)["heroAvatar-default"], timeout: 10, "primary bot avatar")
        parityShot("01-home")
    }

    func test02CreateBot() throws {
        let app = signedInRoster()
        app.buttons["createBotButton"].tap()
        waitFor(app.descendants(matching: .any)["createBotSheet"], timeout: 10, "create sheet")
        waitFor(app.descendants(matching: .any)["createBotPreview"], timeout: 10, "preview")
        Thread.sleep(forTimeInterval: 4.6)
        parityShot("02-create-bot")
    }

    func test37And38Search() throws {
        let app = signedInRoster()
        app.buttons["rosterSearchField"].tap()
        waitFor(app.descendants(matching: .any)["searchScreen"], timeout: 10, "search screen")
        waitFor(app.buttons["searchResult-bot-default"], timeout: 10, "bots listed")
        waitFor(app.keyboards.firstMatch, timeout: 10, "keyboard")
        parityShot("37-search-keyboard")
        app.swipeUp()
        Thread.sleep(forTimeInterval: 0.5)
        app.swipeUp()
        parityShot("38-search-list")
    }
}
