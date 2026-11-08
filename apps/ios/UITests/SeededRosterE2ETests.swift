import XCTest

@MainActor
final class SeededRosterE2ETests: E2ETestCase {
    private static let paritySlugs = [
        "default", "cho-ua", "cho-ai-image-gen", "upwork-hunter",
        "cho-research-app", "cho-hong-hot", "market-researcher", "cho-dinh",
    ]

    override func setUp() async throws {
        let seed = ProcessInfo.processInfo.environment["HERMES_UITEST_SEED"] ?? ""
        try XCTSkipUnless(seed == "parity", "needs a gateway started with --seed parity and HERMES_UITEST_SEED=parity")
        try await super.setUp()
    }

    func test1RosterShowsTheEightParityBots() throws {
        let app = launch(resetCredentials: true)
        signInIfNeeded(app)
        for slug in Self.paritySlugs {
            waitFor(app.buttons["botRow-\(slug)"], timeout: 30, "row \(slug)")
        }
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "botRow-"))
        XCTAssertGreaterThanOrEqual(rows.count, Self.paritySlugs.count, app.debugDescription)
        let untouched = app.buttons["botRow-upwork-hunter"]
        XCTAssertTrue(untouched.label.contains("Tin cuối vẫn là tin anh gửi"), "seeded preview reaches the roster: \(untouched.label)")
        shot(app, "seeded-roster")
    }
}
