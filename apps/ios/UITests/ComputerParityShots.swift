import XCTest

@MainActor
final class ComputerParityShots: ComputerTestCase {
    private static let settleDelay: TimeInterval = 1.5

    private func parityShot(_ referenceName: String) {
        Thread.sleep(forTimeInterval: Self.settleDelay)
        screenShot("parity-\(referenceName)")
    }

    func test18Connecting() throws {
        let app = signedInApp()
        openProfile(app, Self.computerSlug)
        element(app, "profileComputerRow").tap()
        waitFor(element(app, "computerConnecting"), timeout: 20, "connecting state")
        parityShot("18-computer-connecting")
    }

    func test19To21HelpAndDesktop() throws {
        let app = signedInApp()
        openComputer(app)
        waitForStatus(app, "watching")
        Thread.sleep(forTimeInterval: 2)
        parityShot("21-computer-desktop")
        element(app, "computerHelpButton").tap()
        waitFor(element(app, "computerHelp"), timeout: 10, "help sheet")
        parityShot("19-computer-help")
        app.swipeUp()
        waitFor(element(app, "computerHelpRow-imDone"), timeout: 10, "handing it back row")
        parityShot("20-computer-help-scrolled")
    }
}
