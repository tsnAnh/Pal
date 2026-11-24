import AppIntentsTesting
import XCTest

@available(iOS 27.0, *)
@MainActor
class SiriE2ETestCase: E2ETestCase {
    let definitions = IntentDefinitions(bundleIdentifier: "dev.tsnanh.pal")

    func unique(_ text: String) -> String {
        "\(text) \(UUID().uuidString.prefix(6))"
    }

    func bot(_ name: String) async throws -> AnyAppEntity {
        let found = try await definitions.entities["BotEntity"].entities(matching: name)
        return try XCTUnwrap(found.first { $0.identifier.instanceIdentifier == name }, "no bot entity for \(name)")
    }

    func ask(_ bot: AnyAppEntity, _ request: String) async throws -> String {
        let result = try await definitions.intents["AskBotIntent"].makeIntent(bot: bot, request: request).run()
        return try result.value
    }

    func status(of bot: AnyAppEntity) async throws -> String {
        let result = try await definitions.intents["BotStatusIntent"].makeIntent(bot: bot).run()
        let status: AnyAppEnum = try result.value
        return status.rawValue
    }

    func waitForStatus(_ expected: String, of bot: AnyAppEntity, timeout: TimeInterval = 40) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var seen = ""
        while Date() < deadline {
            seen = try await status(of: bot)
            if seen == expected { return }
            try await Task.sleep(for: .seconds(1))
        }
        XCTFail("status never became \(expected); last seen \(seen)")
    }

    func showChat(_ app: XCUIApplication, _ name: String) {
        if app.descendants(matching: .any)["chatScreen"].waitForExistence(timeout: 3) { return }
        openBot(app, name)
    }

    func resetBot(_ bot: AnyAppEntity, app: XCUIApplication) async throws {
        for _ in 0..<4 {
            let current = try await status(of: bot)
            if current == "idle" || current == "offline" { return }
            if current == "working" {
                _ = try await definitions.intents["StopBotIntent"].makeIntent(bot: bot).run()
            } else {
                _ = try? await definitions.intents["AnswerBotIntent"].makeIntent(bot: bot, answer: "vanilla").run()
            }
            try await Task.sleep(for: .seconds(2))
        }
    }

    func stubRequests() throws -> [[String: Any]] {
        let path = try XCTUnwrap(env.stubLogPath, "HERMES_UITEST_STUB_LOG not set")
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
        }
    }

    func waitForStubRequest(
        after seen: Int = 0, timeout: TimeInterval = 60, _ message: String,
        where matches: @escaping ([String: Any]) -> Bool
    ) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let found = try stubRequests().dropFirst(seen).first(where: matches) { return found }
            try await Task.sleep(for: .milliseconds(500))
        }
        XCTFail("no fake LLM request: \(message)")
        throw XCTSkip(message)
    }

    func userTexts(_ request: [String: Any]) -> [String] {
        (request["messages"] as? [[String: Any]] ?? []).filter { $0["role"] as? String == "user" }.compactMap { $0["content"] as? String }
    }
}
