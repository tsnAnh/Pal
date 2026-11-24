import Foundation
import PalProtocol

public enum OwnerOption: Sendable, Hashable {
    case send
    case edit
    case proceed
    case cancel

    public var label: String {
        switch self {
        case .send: String(localized: "Send")
        case .edit: String(localized: "Edit")
        case .proceed: String(localized: "Continue")
        case .cancel: String(localized: "Cancel")
        }
    }

    var labelKey: String? {
        switch self {
        case .send: "send"
        case .edit: "edit"
        case .cancel: "cancel"
        case .proceed: nil
        }
    }

    public func label(using labels: [String: String]?) -> String {
        guard let key = labelKey, let given = labels?[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !given.isEmpty
        else { return label }
        return given
    }

    public var choice: String? {
        switch self {
        case .send, .proceed: "once"
        case .cancel: "deny"
        case .edit: nil
        }
    }
}

extension PendingPrompt {
    public var isOwnerDecision: Bool {
        kind == .approval && question?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    public var isDraft: Bool { draft != nil }

    public var ownerOptions: [OwnerOption] {
        guard kind == .approval else { return [] }
        let canProceed = choices.isEmpty || choices.contains("once")
        let canCancel = choices.isEmpty || choices.contains("deny")
        var options: [OwnerOption] = []
        if canProceed {
            options.append(isDraft ? .send : .proceed)
            if isDraft, command?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false { options.append(.edit) }
        }
        if canCancel { options.append(.cancel) }
        return options
    }

    public var editableText: String? {
        guard ownerOptions.contains(.edit) else { return nil }
        return command
    }

    public func ownerChoice(forLabel label: String) -> String? {
        ownerOptions.first { $0.label(using: labels) == label }?.choice
    }

    func ownerForm() -> PendingPrompt? {
        guard isOwnerDecision, let question else { return nil }
        let options = ownerOptions
        guard !options.isEmpty else { return nil }
        var form = self
        form.questions = [ClarifyQuestion(qid: Self.soleQuestionID, question: question, choices: options.map { $0.label(using: labels) })]
        return form
    }
}

extension ChatSession {
    public func answerOwnerForm(_ prompt: PendingPrompt, answers: [(qid: String, answer: ClarifyForm.Answer)]) async throws {
        guard answers.count == 1, case .answered(let label) = answers[0].answer, let choice = prompt.ownerChoice(forLabel: label) else {
            throw ChatError.unexpectedResponse(method: "approval.respond")
        }
        try await answerApproval(prompt, choice: choice)
    }

    public func answerOwnerEdit(_ prompt: PendingPrompt, text: String) async throws {
        let edited = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let original = prompt.editableText, !edited.isEmpty else {
            throw ChatError.unexpectedResponse(method: "approval.respond")
        }
        let changed = edited != original.trimmingCharacters(in: .whitespacesAndNewlines)
        try await answerApproval(prompt, choice: "once", editedText: changed ? edited : nil)
    }
}
