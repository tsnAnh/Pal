import PalChat
import PalDiagnostics
import PalProtocol

extension ChatModel {
    var isAskingClarify: Bool {
        !(snapshot?.pendingPrompts.isEmpty ?? true)
    }

    func answerForm(_ prompt: PendingPrompt, _ answers: [(qid: String, answer: ClarifyForm.Answer)], settled: ClarifySettled) async throws {
        guard let session else { throw ChatError.notConnected }
        let started = ContinuousClock.now
        switch prompt.kind {
        case .clarify: try await session.answerClarifyForm(prompt, answers: answers)
        case .approval: try await session.answerOwnerForm(prompt, answers: answers)
        }
        markSettled(prompt, settled, since: started)
    }

    func answerEdit(_ prompt: PendingPrompt, text: String, settled: ClarifySettled) async throws {
        guard let session else { throw ChatError.notConnected }
        let started = ContinuousClock.now
        try await session.answerOwnerEdit(prompt, text: text)
        markSettled(prompt, settled, since: started)
    }

    func answer(_ prompt: PendingPrompt, with text: String, settled: ClarifySettled) async -> Bool {
        guard let session else { return false }
        let started = ContinuousClock.now
        do {
            try await session.answerClarify(prompt, answer: text)
        } catch {
            sendError = String(localized: "Your answer could not be sent. Try again.")
            return false
        }
        markSettled(prompt, settled, since: started)
        return true
    }

    func answerFromComposer(_ prompt: PendingPrompt, text: String) {
        let settled = ClarifySettled(question: prompt.question ?? String(localized: "Question"), answer: text)
        Task { _ = await answer(prompt, with: text, settled: settled) }
    }

    func markSettled(_ prompt: PendingPrompt, _ settled: ClarifySettled, since started: ContinuousClock.Instant) {
        PalPerf.event("chat.answer.accepted", label: "clarify", since: started)
        guard settledPrompts[prompt.promptID] != settled else { return }
        settledPrompts[prompt.promptID] = settled
        PalPerf.event("chat.answer.applied", label: "clarify", since: started)
        rebuild()
        PalPerf.event("chat.answer.published", label: "clarify", since: started)
    }

    func settledKind(for card: PromptCard) -> ChatRow.Kind? {
        guard let settled = settledPrompts[card.prompt.promptID] else { return nil }
        return .clarifyAnswered(settled.entries.map { entry in
            ClarifyRecord(question: entry.question, answer: entry.isSkipped ? .skipped : .answered(entry.chosen))
        })
    }

    func hasStaleClarify(_ item: TranscriptItem, _ reuse: BuiltRow) -> Bool {
        guard case .clarify(let card) = item.content, case .clarify? = reuse.kind else { return false }
        return settledPrompts[card.prompt.promptID] != nil
    }
}

extension ChatRow.Kind {
    var isQuestionCard: Bool {
        switch self {
        case .clarify, .clarifyAnswered: true
        default: false
        }
    }
}
