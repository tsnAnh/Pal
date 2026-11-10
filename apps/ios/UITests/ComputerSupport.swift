import XCTest

@MainActor
class ComputerTestCase: BotProfileTestCase {
    static var computerSlug: String { ProcessInfo.processInfo.environment["HERMES_UITEST_COMPUTER_SLUG"] ?? "cho-ua" }

    func openComputer(_ app: XCUIApplication, _ slug: String = ComputerTestCase.computerSlug) {
        openProfile(app, slug)
        let row = element(app, "profileComputerRow")
        waitFor(row, timeout: 20, "computer row")
        row.hit()
        waitFor(element(app, "computerScreen"), timeout: 20, "computer screen")
    }

    func status(_ app: XCUIApplication) -> String {
        let status = element(app, "computerStatus")
        #if os(macOS)
        return status.label
        #else
        return (status.value as? String) ?? ""
        #endif
    }

    func waitForStatus(_ app: XCUIApplication, _ expected: String, timeout: TimeInterval = 30) {
        waitUntil(timeout, "computer status \(expected), now \(status(app))") { status(app) == expected }
    }

    func surfacePoint(_ app: XCUIApplication, x: CGFloat, y: CGFloat) -> XCUICoordinate {
        element(app, "computerSurface").coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
    }

    func inputLog() throws -> [String] {
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["HERMES_UITEST_RFB_LOG"], "HERMES_UITEST_RFB_LOG not set")
        let text = try String(contentsOfFile: path, encoding: .utf8)
        return text.split(separator: "\n").map(String.init)
    }

    func waitForInput(after mark: Int, containing fragment: String, _ message: String, timeout: TimeInterval = 10) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try inputLog().dropFirst(mark).contains(where: { $0.contains(fragment) }) { return }
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTFail("the screen never received \(message) (\(fragment))")
    }
}
