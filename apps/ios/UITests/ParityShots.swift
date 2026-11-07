import HermesDesign
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
        waitFor(app.descendants(matching: .any)["heroAvatar"], timeout: 10, "primary bot avatar")
        parityShot("01-home")
    }
}
