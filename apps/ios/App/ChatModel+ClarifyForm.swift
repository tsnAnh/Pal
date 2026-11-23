import PalChat
import PalProtocol

extension ChatModel {
    var isAskingClarify: Bool {
        snapshot?.pendingPrompts.contains { $0.kind == .clarify } ?? false
    }

    func answerForm(_ prompt: PendingPrompt, _ answers: [(qid: String, answer: ClarifyForm.Answer)]) async throws {
        guard let session else { throw ChatError.notConnected }
        try await session.answerClarifyForm(prompt, answers: answers)
    }
}
