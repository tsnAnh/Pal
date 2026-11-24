import PalChat
import PalProtocol

extension ChatModel {
    var isAskingClarify: Bool {
        !(snapshot?.pendingPrompts.isEmpty ?? true)
    }

    func answerForm(_ prompt: PendingPrompt, _ answers: [(qid: String, answer: ClarifyForm.Answer)]) async throws {
        guard let session else { throw ChatError.notConnected }
        switch prompt.kind {
        case .clarify: try await session.answerClarifyForm(prompt, answers: answers)
        case .approval: try await session.answerOwnerForm(prompt, answers: answers)
        }
    }

    func answerEdit(_ prompt: PendingPrompt, text: String) async throws {
        guard let session else { throw ChatError.notConnected }
        try await session.answerOwnerEdit(prompt, text: text)
    }
}
