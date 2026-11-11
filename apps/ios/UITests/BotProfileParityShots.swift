import XCTest

@MainActor
final class BotProfileParityShots: BotProfileTestCase {
    private static let settleDelay: TimeInterval = 2

    private func parityShot(_ referenceName: String) {
        Thread.sleep(forTimeInterval: Self.settleDelay)
        screenShot("parity-\(referenceName)")
    }

    func test17To24ProfileAndMenu() throws {
        let app = signedInApp()
        openProfile(app, Self.primarySlug)
        waitFor(element(app, "profileRoutinesRow"), timeout: 20, "routines row")
        waitUntil(20, "computer status loaded") { !element(app, "profileComputerRow").label.isEmpty }
        parityShot("17-bot-profile")
        element(app, "profileMoreButton").tap()
        waitFor(app.buttons["Copy ID"], timeout: 10, "menu item")
        parityShot("24-bot-profile-menu")
    }

    func test16Library() throws {
        let app = signedInApp()
        openProfile(app, Self.primarySlug)
        element(app, "profileLibraryRow").tap()
        waitFor(element(app, "libraryScreen"), timeout: 20, "library screen")
        waitFor(element(app, "libraryCard-thisWeek"), timeout: 30, "this week section")
        Thread.sleep(forTimeInterval: 4)
        parityShot("16-library")
    }

    func test23Routines() throws {
        let app = signedInApp()
        openProfile(app, Self.primarySlug)
        element(app, "profileRoutinesRow").tap()
        waitFor(element(app, "routinesCard"), timeout: 30, "routines list")
        parityShot("23-routines")
    }

    func test22AddToSlack() throws {
        let app = signedInApp(connectedServices: ["slack"])
        openProfile(app, Self.primarySlug)
        element(app, "profileSlackRow").tap()
        waitFor(element(app, "slackConnectButton"), timeout: 30, "connect button")
        parityShot("22-add-to-slack")
    }
}
