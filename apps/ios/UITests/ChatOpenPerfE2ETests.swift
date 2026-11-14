import XCTest

@MainActor
final class ChatOpenPerfE2ETests: E2ETestCase {
    private static let bundleID = "dev.tsnanh.hermes.bot"
    private static let reapSeconds: TimeInterval = 26
    private static let dwellSeconds: TimeInterval = 8

    private var lastDetach: Date?

    override func setUp() async throws {
        let seed = ProcessInfo.processInfo.environment["HERMES_UITEST_SEED"] ?? ""
        try XCTSkipUnless(seed == "perf", "needs the long Bot Chats seeded by apps/ios/Tools/perf/run-baseline and HERMES_UITEST_SEED=perf")
        #if os(macOS)
        throw XCTSkip("the perf harness drives the iOS simulator")
        #endif
        try await super.setUp()
    }

    private func record(_ iteration: Int, _ scenario: String, _ bot: String, _ event: String) {
        guard let directory = env.shotsDirectory else { return }
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let path = directory + "/perf-events.tsv"
        let line = String(format: "%.3f\t%d\t%@\t%@\t%@\n", Date().timeIntervalSince1970, iteration, scenario, bot, event)
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    }

    private func chatCacheFiles() -> [URL] {
        let containers = URL(fileURLWithPath: NSHomeDirectory()).deletingLastPathComponent()
        let entries = (try? FileManager.default.contentsOfDirectory(at: containers, includingPropertiesForKeys: nil)) ?? []
        for entry in entries {
            let metadata = entry.appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist")
            guard let data = try? Data(contentsOf: metadata),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  plist["MCMMetadataIdentifier"] as? String == Self.bundleID
            else { continue }
            let cache = entry.appendingPathComponent("Library/Application Support/cache")
            let accounts = (try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)) ?? []
            return accounts.flatMap { account in
                ((try? FileManager.default.contentsOfDirectory(at: account, includingPropertiesForKeys: nil)) ?? [])
                    .filter { $0.lastPathComponent.hasPrefix("chat-") }
            }
        }
        return []
    }

    private func clearChatCaches() {
        for file in chatCacheFiles() { try? FileManager.default.removeItem(at: file) }
        XCTAssertTrue(chatCacheFiles().isEmpty, "chat caches cleared")
    }

    private func waitForGatewayToReleaseChats() {
        guard let lastDetach else { return }
        let remaining = Self.reapSeconds - Date().timeIntervalSince(lastDetach)
        if remaining > 0 { Thread.sleep(forTimeInterval: remaining) }
    }

    @discardableResult
    private func launchSignedIn(_ iteration: Int, _ scenario: String) -> XCUIApplication {
        record(iteration, scenario, "-", "launch-begin")
        let app = launch()
        signInIfNeeded(app)
        waitFor(roster(app), timeout: 40, "roster")
        waitFor(app.buttons["botRow-bot-alpha"], timeout: 40, "alpha row")
        waitFor(app.buttons["botRow-bot-beta"], timeout: 40, "beta row")
        record(iteration, scenario, "-", "roster-visible")
        return app
    }

    private func open(_ app: XCUIApplication, _ iteration: Int, _ scenario: String, _ bot: String) {
        record(iteration, scenario, bot, "tap-bot")
        app.buttons["botRow-\(bot)"].hit()
        waitFor(app.descendants(matching: .any)["chatScreen"], timeout: 30, "chat screen")
        record(iteration, scenario, bot, "chat-visible")
        let reply = app.descendants(matching: .any).matching(identifier: "assistantBubble").firstMatch
        waitFor(reply, timeout: 90, "transcript content")
        record(iteration, scenario, bot, "content-visible")
        Thread.sleep(forTimeInterval: Self.dwellSeconds)
        record(iteration, scenario, bot, "dwell-done")
    }

    private func leave(_ app: XCUIApplication, _ iteration: Int, _ scenario: String, _ bot: String) {
        app.navigationBars.buttons.element(boundBy: 0).tap()
        waitFor(app.buttons["botRow-\(bot)"], timeout: 20, "roster after the chat")
        lastDetach = Date()
        record(iteration, scenario, bot, "left-chat")
    }

    func testOpenLongChatsColdAndWarm() throws {
        let iterations = Int(ProcessInfo.processInfo.environment["HERMES_PERF_ITERATIONS"] ?? "") ?? 5
        let bots = ["bot-alpha", "bot-beta"]
        launchSignedIn(-1, "sign-in").terminate()
        for iteration in 0..<iterations {
            let order = iteration.isMultiple(of: 2) ? bots : bots.reversed()
            clearChatCaches()
            waitForGatewayToReleaseChats()

            let cold = launchSignedIn(iteration, "A-cold-cache-cold-gateway")
            for bot in order {
                open(cold, iteration, "A-cold-cache-cold-gateway", bot)
                leave(cold, iteration, "A-cold-cache-cold-gateway", bot)
                open(cold, iteration, "B-warm-cache-warm-gateway", bot)
                leave(cold, iteration, "B-warm-cache-warm-gateway", bot)
            }
            cold.terminate()
            waitForGatewayToReleaseChats()

            let relaunched = launchSignedIn(iteration, "C-warm-cache-cold-gateway")
            for bot in order {
                open(relaunched, iteration, "C-warm-cache-cold-gateway", bot)
                leave(relaunched, iteration, "C-warm-cache-cold-gateway", bot)
            }
            relaunched.terminate()
        }
    }
}
