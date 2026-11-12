import XCTest

@MainActor
final class ParityConnectApps: ConnectAppsTestCase {
    private static let settleDelay: TimeInterval = 3

    private func parityShot(_ referenceName: String) {
        Thread.sleep(forTimeInterval: Self.settleDelay)
        screenShot("parity-\(referenceName)")
    }

    private func readyCatalog() -> XCUIApplication {
        let app = launchConnectApps()
        waitForCatalog(app)
        return app
    }

    func test03All() throws {
        _ = readyCatalog()
        parityShot("03-connect-apps-all")
    }

    func test04Scroll1() throws {
        let app = readyCatalog()
        app.scrollViews.firstMatch.swipeUp(velocity: .slow)
        app.scrollViews.firstMatch.swipeUp(velocity: .slow)
        parityShot("04-connect-apps-scroll1")
    }

    func test05Scroll2() throws {
        let app = readyCatalog()
        for _ in 0..<5 { app.scrollViews.firstMatch.swipeUp(velocity: .slow) }
        parityShot("05-connect-apps-scroll2")
    }

    func test07Communication() throws {
        let app = readyCatalog()
        tapChip(app, "Communication")
        parityShot("07-connect-apps-communication")
    }

    func test08Design() throws {
        let app = readyCatalog()
        tapChip(app, "Design and media")
        parityShot("08-connect-apps-design")
    }

    func test09Code() throws {
        let app = readyCatalog()
        tapChip(app, "Developer")
        parityShot("09-connect-apps-code")
    }

    func test10YourPlugins() throws {
        let app = readyCatalog()
        app.buttons["connectedCountButton"].tap()
        waitFor(app.descendants(matching: .any)["connectApps-title"], timeout: 10, "Your plugins page")
        parityShot("10-your-plugins")
    }
}
