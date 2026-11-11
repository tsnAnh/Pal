import PalDesign
import XCTest

@MainActor
final class LiveBotThreadE2ETests: E2ETestCase {
    private let reply = "Đã nhận, em xử lý ngay."
    private let marker = "LIVE-DM-\(UUID().uuidString.prefix(8))"

    override func setUp() async throws {
        let seed = ProcessInfo.processInfo.environment["HERMES_UITEST_SEED"] ?? ""
        try XCTSkipUnless(seed == "parity", "needs a gateway started with --seed parity and HERMES_UITEST_SEED=parity")
        try await super.setUp()
    }

    func testThreadScreenShowsAMessageThatArrivesWhileItIsOpen() throws {
        let app = launch(extraArguments: ["-\(AppearanceStore.defaultsKey)", AppearanceMode.dark.rawValue])
        signInIfNeeded(app)
        openBot(app, "cho-research-app")
        let link = app.buttons["botThreadLink"].firstMatch
        waitFor(link, timeout: 30, "bot thread link row")
        let linksBefore = app.buttons.matching(identifier: "botThreadLink").count
        link.tap()
        waitFor(app.descendants(matching: .any)["threadScreen"], timeout: 20, "thread screen")
        waitFor(app.descendants(matching: .any)["threadMessage"].firstMatch, timeout: 20, "thread messages")
        XCTAssertEqual(bubbles(app, "threadMessage", containing: marker).count, 0)
        let repliesBefore = bubbles(app, "threadMessage", containing: reply).count
        shot(app, "thread-live-ready-\(marker)")
        let thread = app.descendants(matching: .any)["threadScreen"]
        for _ in 0..<8 { thread.swipeUp(velocity: .fast) }

        waitFor(bubbles(app, "threadMessage", containing: marker).firstMatch, timeout: 120, "the live message without reopening the thread")
        let replies = bubbles(app, "threadMessage", containing: reply)
        let replied = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count > %d", repliesBefore), object: replies)
        XCTAssertEqual(XCTWaiter().wait(for: [replied], timeout: 60), .completed, "the live reply")
        shot(app, "thread-live-updated")

        app.navigationBars.buttons.firstMatch.tap()
        waitFor(app.buttons["botThreadLink"].firstMatch, timeout: 20, "chat returns")
        let links = app.buttons.matching(identifier: "botThreadLink")
        let grew = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count > %d", linksBefore), object: links)
        XCTAssertEqual(XCTWaiter().wait(for: [grew], timeout: 30), .completed, "the chat gains a link row for the new exchange")
    }
}
