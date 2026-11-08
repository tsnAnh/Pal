import XCTest

@MainActor
class ComputerTestCase: BotProfileTestCase {
    static let computerSlug = "cho-ua"

    func openComputer(_ app: XCUIApplication, _ slug: String = ComputerTestCase.computerSlug) {
        openProfile(app, slug)
        let row = element(app, "profileComputerRow")
        waitFor(row, timeout: 20, "computer row")
        row.tap()
        waitFor(element(app, "computerScreen"), timeout: 20, "computer screen")
    }

    func status(_ app: XCUIApplication) -> String {
        (element(app, "computerStatus").value as? String) ?? ""
    }

    func waitForStatus(_ app: XCUIApplication, _ expected: String, timeout: TimeInterval = 30) {
        waitUntil(timeout, "computer status \(expected), now \(status(app))") { status(app) == expected }
    }

    func surfacePoint(_ app: XCUIApplication, x: CGFloat, y: CGFloat) -> XCUICoordinate {
        element(app, "computerSurface").coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
    }
}
