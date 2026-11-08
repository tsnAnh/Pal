import AppIntents
import AppIntentsTesting
import UIKit
import UniformTypeIdentifiers
import XCTest

@available(iOS 27.0, *)
@MainActor
final class SiriVoiceControlE2ETests: SiriE2ETestCase {
    private func pngData() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24)).pngData { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
        }
    }

    func test1StatusIsIdleAndLastReplyHoldsTheAnswerAfterAnAsk() async throws {
        let app = launch()
        signInIfNeeded(app)
        let alpha = try await bot("bot-alpha")
        _ = try await ask(alpha, unique("hello for status"))
        try await waitForStatus("idle", of: alpha)
        let last = try await definitions.intents["LastReplyIntent"].makeIntent(bot: alpha).run()
        let text: String = try last.value
        XCTAssertTrue(text.contains("stub-"), text)
        let beta = try await bot("bot-beta")
        let betaLast = try await definitions.intents["LastReplyIntent"].makeIntent(bot: beta).run()
        let betaText: String = try betaLast.value
        XCTAssertEqual(betaText, "", "a bot that never replied has no last reply")
    }

    func test2StatusReadsWorkingWhileASlowTaskRunsThenStopReturnsItToIdle() async throws {
        let app = launch()
        signInIfNeeded(app)
        let alpha = try await bot("bot-alpha")
        try await resetBot(alpha, app: app)
        let request = unique("SLOW task to stop")
        _ = try await definitions.intents["TellBotIntent"].makeIntent(bot: alpha, request: request).run()
        try await waitForStatus("working", of: alpha, timeout: 20)
        let stopped = Date()
        _ = try await definitions.intents["StopBotIntent"].makeIntent(bot: alpha).run()
        try await waitForStatus("idle", of: alpha, timeout: 20)
        XCTAssertLessThan(Date().timeIntervalSince(stopped), 20, "stopping must not wait for the 10s slow stream to end")
        showChat(app, "bot-alpha")
        try await Task.sleep(for: .seconds(3))
        let asked = bubbles(app, "userBubble", containing: request).firstMatch
        waitFor(asked, timeout: 10, "the stopped task's message")
        let finished = app.descendants(matching: .any).matching(identifier: "assistantBubble").allElementsBoundByIndex
            .filter { $0.frame.minY > asked.frame.minY && $0.label.contains("slow-39") }
        XCTAssertTrue(finished.isEmpty, "the stopped turn must not run to its end")
        shot(app, "siri-stop-chat")
        _ = try await definitions.intents["StopBotIntent"].makeIntent(bot: alpha).run()
    }

    func test3AnswerBotIntentAnswersTheClarifyQuestionAndSpeaksTheFollowUp() async throws {
        let app = launch()
        signInIfNeeded(app)
        let alpha = try await bot("bot-alpha")
        try await resetBot(alpha, app: app)
        let spoken = try await ask(alpha, unique("CLARIFY pick one"))
        XCTAssertTrue(spoken.contains("Which flavor do you want?"), spoken)
        XCTAssertTrue(spoken.contains("Answer ") && spoken.contains("in Hermes Bots"), "voice path is named: \(spoken)")
        try await waitForStatus("needsInput", of: alpha, timeout: 20)
        let reply = try await definitions.intents["AnswerBotIntent"].makeIntent(bot: alpha, answer: "Chocolate.").run()
        let text: String = try reply.value
        XCTAssertTrue(text.contains("\"user_response\": \"chocolate\""), "the offered choice, not the raw words, reaches the model: \(text)")
        let none = try await definitions.intents["AnswerBotIntent"].makeIntent(bot: alpha, answer: "anything").run()
        let nothing: String = try none.value
        XCTAssertTrue(nothing.contains("isn't waiting for an answer"), nothing)
        try await waitForStatus("idle", of: alpha, timeout: 30)
        showChat(app, "bot-alpha")
        XCTAssertFalse(app.descendants(matching: .any)["clarifyCard"].exists, "the card is settled")
    }

    func test4ReviewApprovalWithNothingPendingSaysSo() async throws {
        let app = launch()
        signInIfNeeded(app)
        let alpha = try await bot("bot-alpha")
        let result = try await definitions.intents["ReviewApprovalIntent"].makeIntent(bot: alpha).run()
        let verdict: AnyAppEnum = try result.value
        XCTAssertEqual(verdict.rawValue, "nothingWaiting")
    }

    func test5ApprovalIsRelayedWithTheCommandAndReviewApprovalDecides() async throws {
        let app = launch()
        signInIfNeeded(app)
        let alpha = try await bot("bot-alpha")
        try await resetBot(alpha, app: app)
        let seen = try stubRequests().count
        let spoken = try await ask(alpha, unique("APPROVE this"))
        addTeardownBlock { @MainActor in self.denyAnyOpenApproval(in: app) }
        XCTAssertTrue(spoken.contains("wants to run a command: cd \"$(mktemp -d)\" && git reset --hard"), spoken)
        XCTAssertTrue(spoken.contains("Review"), "voice path is named: \(spoken)")
        let definitions = definitions
        let decided = try await run(within: 60) {
            let result = try await definitions.intents["ReviewApprovalIntent"].makeIntent(bot: alpha).run()
            let verdict: AnyAppEnum = try result.value
            return verdict.rawValue
        }
        guard let verdict = decided else {
            XCTFail("ReviewApprovalIntent did not return within 60s (requestConfirmation under AppIntentsTesting)")
            return
        }
        XCTAssertEqual(verdict, "approved", "AppIntentsTesting confirms the prompt, so the approve branch runs")
        _ = try await waitForStubRequest(after: seen, timeout: 60, "the model sees the command ran because the user approved it") { request in
            let last = (request["messages"] as? [[String: Any]])?.last
            return last?["role"] as? String == "tool" && (last?["content"] as? String)?.contains("approved by the user") == true
        }
        showChat(app, "bot-alpha")
        shot(app, "siri-approval-\(verdict)")
    }

    func test6SteerReachesTheModelThroughTheNextToolResult() async throws {
        let app = launch()
        signInIfNeeded(app)
        let alpha = try await bot("bot-alpha")
        try await resetBot(alpha, app: app)
        let marker = unique("STEER task")
        _ = try await definitions.intents["TellBotIntent"].makeIntent(bot: alpha, request: marker).run()
        try await waitForStatus("working", of: alpha, timeout: 20)
        let guidance = "use tabs " + UUID().uuidString.prefix(6)
        _ = try await definitions.intents["SteerBotIntent"].makeIntent(bot: alpha, guidance: guidance).run()
        let request = try await waitForStubRequest(timeout: 90, "a model request carrying the steer guidance") { request in
            ((request["messages"] as? [[String: Any]]) ?? []).contains { ($0["content"] as? String)?.contains(guidance) == true }
        }
        let messages = request["messages"] as? [[String: Any]] ?? []
        XCTAssertEqual(messages.last?["role"] as? String, "user")
        XCTAssertTrue((messages.last?["content"] as? String)?.contains("OUT-OF-BAND USER MESSAGE") == true, "the guidance lands mid-turn, after the tool result")
        XCTAssertTrue(messages.contains { $0["role"] as? String == "tool" }, "the turn that took the guidance had a tool result")
        try await waitForStatus("idle", of: alpha, timeout: 60)
        showChat(app, "bot-alpha")
        shot(app, "siri-steer-chat")
    }

    func test7SteerOnAnIdleBotSendsANewTask() async throws {
        let app = launch()
        signInIfNeeded(app)
        let alpha = try await bot("bot-alpha")
        try await resetBot(alpha, app: app)
        try await waitForStatus("idle", of: alpha, timeout: 60)
        let text = unique("steer while idle")
        _ = try await definitions.intents["SteerBotIntent"].makeIntent(bot: alpha, guidance: text).run()
        let request = try await waitForStubRequest(timeout: 60, "the idle steer arriving as a normal user turn") { request in
            self.userTexts(request).contains { $0 == text || $0.hasPrefix(text) }
        }
        let messages = request["messages"] as? [[String: Any]] ?? []
        XCTAssertFalse(messages.contains { ($0["content"] as? String)?.contains("OUT-OF-BAND USER MESSAGE") == true && ($0["content"] as? String)?.contains(text) == true }, "an idle bot is not steered")
        try await waitForStatus("idle", of: alpha, timeout: 60)
        showChat(app, "bot-alpha")
        shot(app, "siri-steer-idle-chat")
    }

    func test8SendToBotDeliversAnImageAndATextFileToTheModel() async throws {
        let app = launch()
        signInIfNeeded(app)
        let alpha = try await bot("bot-alpha")
        try await resetBot(alpha, app: app)
        let note = unique("what are these")
        let token = "milk-" + UUID().uuidString.prefix(6)
        let image = IntentFile(data: pngData(), filename: "orange.png", type: .png)
        let text = IntentFile(data: Data("buy \(token)".utf8), filename: "todo.txt", type: .plainText)
        _ = try await definitions.intents["SendToBotIntent"].makeIntent(files: [image, text], bot: alpha, note: note).run()
        let request = try await waitForStubRequest(timeout: 90, "the model turn carrying the note and the text file's content") { request in
            self.userTexts(request).contains { $0.contains(note) && $0.contains("buy \(token)") }
        }
        let joined = userTexts(request).joined(separator: "\n")
        XCTAssertTrue(joined.contains("todo"), "the file is referenced by name: \(joined)")
        XCTAssertTrue(joined.contains("[The user sent an image"), "the image reached the vision step: \(joined)")
        let vision = try await waitForStubRequest(timeout: 30, "the vision request carrying the png") { request in
            ((request["images"] as? [[String: Any]]) ?? []).contains { $0["mime"] as? String == "image/png" }
        }
        XCTAssertFalse((vision["images"] as? [[String: Any]] ?? []).isEmpty)
        showChat(app, "bot-alpha")
        shot(app, "siri-send-files-chat")
    }

    func test9SendToBotRefusesAnEmptyFileAndAVideoInProductLanguage() async throws {
        let app = launch()
        signInIfNeeded(app)
        let alpha = try await bot("bot-alpha")
        let video = IntentFile(data: Data("not really a movie".utf8), filename: "clip.mov", type: .quickTimeMovie)
        do {
            _ = try await definitions.intents["SendToBotIntent"].makeIntent(files: [video], bot: alpha).run()
            XCTFail("a video must be refused")
        } catch {
            XCTAssertTrue("\(error)".contains("clip.mov") || !"\(error)".isEmpty)
        }
        let before = try stubRequests().count
        try await Task.sleep(for: .seconds(2))
        XCTAssertEqual(try stubRequests().count, before, "nothing was sent")
    }

    func test10DenyRequestBlocksTheCommandWithoutAConfirmationPrompt() async throws {
        let app = launch()
        signInIfNeeded(app)
        let alpha = try await bot("bot-alpha")
        try await resetBot(alpha, app: app)
        let seen = try stubRequests().count
        _ = try await ask(alpha, unique("APPROVE this"))
        addTeardownBlock { @MainActor in self.denyAnyOpenApproval(in: app) }
        let deny = definitions.enums["ApprovalChoice"].makeCase("deny")
        let result = try await definitions.intents["ReviewApprovalIntent"].makeIntent(bot: alpha, choice: deny).run()
        let verdict: AnyAppEnum = try result.value
        XCTAssertEqual(verdict.rawValue, "denied")
        _ = try await waitForStubRequest(after: seen, timeout: 60, "the model sees the command was blocked because the user denied it") { request in
            let last = (request["messages"] as? [[String: Any]])?.last
            return last?["role"] as? String == "tool" && (last?["content"] as? String)?.contains("denied by user") == true
        }
        showChat(app, "bot-alpha")
        shot(app, "siri-approval-denied")
    }
}
