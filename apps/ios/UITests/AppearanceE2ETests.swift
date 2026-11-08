import XCTest

@MainActor
final class AppearanceE2ETests: E2ETestCase {
    private let appearances: [(name: String, value: XCUIDevice.Appearance)] = [("light", .light), ("dark", .dark)]

    func test1SignInScreenFollowsSystemAppearance() throws {
        for appearance in appearances {
            XCUIDevice.shared.appearance = appearance.value
            let app = launch(resetCredentials: true)
            waitFor(app.textFields["baseURLField"], timeout: 15, "sign-in form")
            shot(app, "appearance-\(appearance.name)-connection-signed-out")
            app.terminate()
        }
    }

    func test2RosterChatAndSettingsFollowSystemAppearance() throws {
        let app = launch(resetCredentials: true)
        signInIfNeeded(app)
        for appearance in appearances {
            XCUIDevice.shared.appearance = appearance.value
            waitFor(roster(app), timeout: 15, "roster")
            shot(app, "appearance-\(appearance.name)-roster")

            openBot(app, "bot-alpha")
            send(app, "hello alpha \(appearance.name)")
            waitFor(bubbles(app, "assistantBubble", containing: "stub-").firstMatch, timeout: 60, "streamed reply")
            shot(app, "appearance-\(appearance.name)-chat-white-bot")
            app.navigationBars.buttons.element(boundBy: 0).tap()

            openBot(app, "bot-beta")
            send(app, "CLARIFY pick one \(appearance.name)")
            waitFor(app.descendants(matching: .any)["clarifyCard"], timeout: 60, "clarify card")
            shot(app, "appearance-\(appearance.name)-chat-clarify")
            app.buttons["clarifyChoice-0"].tap()
            waitFor(bubbles(app, "assistantBubble", containing: "Got it").firstMatch, timeout: 60, "answer")
            app.navigationBars.buttons.element(boundBy: 0).tap()

            waitFor(roster(app), timeout: 15, "roster again")
            app.buttons["userAvatarButton"].tap()
            waitFor(app.descendants(matching: .any)["settingsSheet"], timeout: 15, "settings")
            shot(app, "appearance-\(appearance.name)-settings")
            app.buttons["settingsSheet-close"].tap()
        }
    }
}
