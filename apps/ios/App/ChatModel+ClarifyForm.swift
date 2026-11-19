import PalChat
import PalProtocol

extension ChatModel {
    var isAskingClarify: Bool {
        snapshot?.pendingPrompts.contains { $0.kind == .clarify } ?? false
    }

    func answerForm(_ prompt: PendingPrompt, _ answers: [(qid: String, answer: ClarifyForm.Answer)]) async -> Bool {
        guard let session else { return false }
        do {
            try await session.answerClarifyForm(prompt, answers: answers)
            return true
        } catch {
            sendError = String(localized: "Your answer could not be sent. Try again.")
            return false
        }
    }
}
