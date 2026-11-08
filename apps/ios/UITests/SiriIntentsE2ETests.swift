import AppIntentsTesting
import XCTest

@available(iOS 27.0, *)
@MainActor
final class SiriIntentsE2ETests: E2ETestCase {
    private let definitions = IntentDefinitions(bundleIdentifier: "dev.tsnanh.hermes.bot")

    private func unique(_ text: String) -> String {
        "\(text) \(UUID().uuidString.prefix(6))"
    }

    private func bot(_ name: String) async throws -> AnyAppEntity {
        let found = try await definitions.entities["BotEntity"].entities(matching: name)
        return try XCTUnwrap(found.first { $0.identifier.instanceIdentifier == name }, "no bot entity for \(name)")
    }

    private func ask(_ bot: AnyAppEntity, _ request: String) async throws -> String {
        let result = try await definitions.intents["AskBotIntent"].makeIntent(bot: bot, request: request).run()
        return try result.value
    }

    func test1EntityQueryFindsBotsByNameAndSlug() async throws {
        let app = launch(resetCredentials: true)
        signInIfNeeded(app)
        let byName = try await definitions.entities["BotEntity"].entities(matching: "alpha")
        XCTAssertEqual(byName.map(\.identifier.instanceIdentifier), ["bot-alpha"])
        let suggested = try await definitions.entities["BotEntity"].suggestedEntities()
        XCTAssertTrue(Set(suggested.map(\.identifier.instanceIdentifier)).isSuperset(of: ["bot-alpha", "bot-beta", "default"]))
        for entity in suggested {
            let isDefault: Bool = try entity.isDefault
            XCTAssertEqual(isDefault, entity.identifier.instanceIdentifier == "default", entity.identifier.instanceIdentifier)
        }
    }

    func test2AskReturnsTheReplyAndTheChatShowsTheTurnOnce() async throws {
        let app = launch()
        signInIfNeeded(app)
        let alpha = try await bot("bot-alpha")
        let text = unique("hello from siri")
        let reply = try await ask(alpha, text)
        XCTAssertTrue(reply.contains("stub-"), reply)
        openBot(app, "bot-alpha")
        waitFor(bubbles(app, "assistantBubble", containing: "stub-").firstMatch, timeout: 30, "reply in chat")
        XCTAssertEqual(bubbles(app, "userBubble", containing: text).count, 1)
        shot(app, "siri-ask-chat")
    }

    func test3TellReturnsBeforeTheReplyAndTheReplyLandsInTheChat() async throws {
        let app = launch()
        signInIfNeeded(app)
        let alpha = try await bot("bot-alpha")
        let text = unique("SLOW tell from siri")
        let started = Date()
        let result = try await definitions.intents["TellBotIntent"].makeIntent(bot: alpha, request: text).run()
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertNotNil(result)
        XCTAssertLessThan(elapsed, 8, "tell must not wait for the 10s slow reply")
        openBot(app, "bot-alpha")
        waitFor(bubbles(app, "userBubble", containing: text).firstMatch, timeout: 30, "siri message in chat")
        waitFor(bubbles(app, "assistantBubble", containing: "slow-39").firstMatch, timeout: 90, "reply finished in chat")
        XCTAssertEqual(bubbles(app, "userBubble", containing: text).count, 1)
        shot(app, "siri-tell-chat")
    }

    func test4AskWhileTheChatIsOpenSharesTheSessionAndAddsOneBubble() async throws {
        let app = launch()
        signInIfNeeded(app)
        openBot(app, "bot-alpha")
        let alpha = try await bot("bot-alpha")
        let text = unique("ask while chat is open")
        let reply = try await ask(alpha, text)
        XCTAssertTrue(reply.contains("stub-"), reply)
        waitFor(bubbles(app, "userBubble", containing: text).firstMatch, timeout: 30, "siri message in the open chat")
        waitFor(bubbles(app, "assistantBubble", containing: "stub-").firstMatch, timeout: 30, "reply in the open chat")
        XCTAssertEqual(bubbles(app, "userBubble", containing: text).count, 1)
        shot(app, "siri-ask-open-chat")
    }

    func test5ClarifyQuestionIsRelayedAndTheChatOpensOnTheCard() async throws {
        let app = launch()
        signInIfNeeded(app)
        let alpha = try await bot("bot-alpha")
        let spoken = try await ask(alpha, "CLARIFY pick one")
        XCTAssertTrue(spoken.contains("Which flavor do you want?"), spoken)
        if !app.descendants(matching: .any)["chatScreen"].waitForExistence(timeout: 10) { openBot(app, "bot-alpha") }
        let card = app.descendants(matching: .any)["clarifyCard"]
        waitFor(card, timeout: 30, "clarify card in chat")
        shot(app, "siri-clarify-chat")
        app.buttons["clarifyChoice-0"].tap()
        waitFor(bubbles(app, "assistantBubble", containing: "\"user_response\": \"vanilla\"").firstMatch, timeout: 60, "answering in the chat completes the turn")
    }

    func test6AskWaitsForASlowReplyWithoutGivingUp() async throws {
        let app = launch()
        signInIfNeeded(app)
        let alpha = try await bot("bot-alpha")
        let text = unique("SLOW ask from siri")
        let started = Date()
        let reply = try await ask(alpha, text)
        XCTAssertGreaterThan(Date().timeIntervalSince(started), 8, "the slow stream takes about 10s")
        XCTAssertTrue(reply.contains("slow-39"), reply)
        openBot(app, "bot-alpha")
        XCTAssertEqual(bubbles(app, "userBubble", containing: text).count, 1)
        waitFor(bubbles(app, "assistantBubble", containing: "slow-39").firstMatch, timeout: 30, "reply in chat")
    }
}
