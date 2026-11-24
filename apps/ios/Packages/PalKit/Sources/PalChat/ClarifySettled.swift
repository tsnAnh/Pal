import Foundation
import PalProtocol

public struct ClarifySettled: Sendable, Hashable {
    public struct Entry: Sendable, Hashable {
        public var question: String
        public var chosen: [String]

        public init(question: String, chosen: [String]) {
            self.question = question
            self.chosen = chosen
        }

        public var isSkipped: Bool { chosen.isEmpty }
    }

    public var entries: [Entry]

    public init(entries: [Entry]) {
        self.entries = entries
    }

    public init(records: [ClarifyRecord]) {
        entries = records.map { record in
            guard case .answered(let picks) = record.answer else { return Entry(question: record.question, chosen: []) }
            return Entry(question: record.question, chosen: picks.filter { !$0.isEmpty })
        }
    }

    public init?(form: ClarifyForm) {
        guard form.canSubmit else { return nil }
        entries = form.questions.indices.map { Entry(question: form.questions[$0].question, chosen: form.chosenRows(at: $0) ?? []) }
    }

    public init(question: String, option: OwnerOption) {
        entries = [Entry(question: question, chosen: [option.label])]
    }

    public init(question: String, answer: String?) {
        entries = [Entry(question: question, chosen: answer.flatMap { $0.isEmpty ? nil : [$0] } ?? [])]
    }

    public var isSingle: Bool { entries.count == 1 }
}

extension ClarifyForm {
    public func chosenRows(at index: Int) -> [String]? {
        guard let answer = answer(at: index) else { return nil }
        if case .skipped = answer { return [] }
        let question = questions[index]
        let draft = drafts[index]
        let typed = draft.typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let labels = draft.picked.sorted().compactMap { question.choices.indices.contains($0) ? question.choices[$0] : nil }
        if question.multiSelect { return typed.isEmpty ? labels : labels + [typed] }
        return typed.isEmpty ? Array(labels.prefix(1)) : [typed]
    }
}
