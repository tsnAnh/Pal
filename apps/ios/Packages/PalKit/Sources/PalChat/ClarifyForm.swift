import Foundation
import PalProtocol

public struct ClarifyForm: Sendable, Equatable {
    public struct Draft: Sendable, Equatable {
        public var picked: Set<Int> = []
        public var typed = ""
        public var skipped = false

        public init(picked: Set<Int> = [], typed: String = "", skipped: Bool = false) {
            self.picked = picked
            self.typed = typed
            self.skipped = skipped
        }
    }

    public enum Answer: Sendable, Equatable {
        case answered(String)
        case skipped
    }

    public struct Recap: Sendable, Equatable {
        public var answered: Int
        public var skipped: Int
    }

    public let questions: [ClarifyQuestion]
    public private(set) var drafts: [Draft]
    public private(set) var page = 0

    public init(questions: [ClarifyQuestion]) {
        self.questions = questions
        drafts = Array(repeating: Draft(), count: questions.count)
    }

    public var count: Int { questions.count }
    public var showsPaging: Bool { count > 1 }
    public var isFirst: Bool { page == 0 }
    public var isLast: Bool { page == count - 1 }
    public var current: ClarifyQuestion { questions[page] }
    public var currentDraft: Draft { drafts[page] }
    public var hasChoices: Bool { !current.choices.isEmpty }
    public var canAdvance: Bool { isAnswered(page) }
    public var canSubmit: Bool { drafts.indices.allSatisfy(isAnswered) }

    public var recap: Recap {
        var recap = Recap(answered: 0, skipped: 0)
        for index in drafts.indices {
            switch answer(at: index) {
            case .answered?: recap.answered += 1
            case .skipped?: recap.skipped += 1
            case nil: break
            }
        }
        return recap
    }

    public func isAnswered(_ index: Int) -> Bool {
        answer(at: index) != nil
    }

    public func answer(at index: Int) -> Answer? {
        guard drafts.indices.contains(index) else { return nil }
        let draft = drafts[index]
        if draft.skipped { return .skipped }
        let question = questions[index]
        return ClarifyAnswer.wire(choices: question.choices, selection: draft.picked, typed: draft.typed, multiSelect: question.multiSelect)
            .map(Answer.answered)
    }

    public var payload: [(qid: String, answer: Answer)]? {
        guard canSubmit else { return nil }
        return questions.indices.compactMap { index in
            answer(at: index).map { (qid: questions[index].qid, answer: $0) }
        }
    }

    public mutating func pick(_ index: Int) {
        guard current.choices.indices.contains(index) else { return }
        var draft = drafts[page]
        draft.skipped = false
        if current.multiSelect {
            if draft.picked.contains(index) { draft.picked.remove(index) } else { draft.picked.insert(index) }
        } else {
            draft.picked = [index]
            draft.typed = ""
        }
        drafts[page] = draft
    }

    public mutating func setTyped(_ text: String) {
        var draft = drafts[page]
        draft.typed = text
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft.skipped = false
            if !current.multiSelect { draft.picked = [] }
        }
        drafts[page] = draft
    }

    public mutating func skip() {
        drafts[page] = Draft(skipped: true)
    }

    @discardableResult
    public mutating func advance() -> Bool {
        guard canAdvance, !isLast else { return false }
        page += 1
        return true
    }

    @discardableResult
    public mutating func back() -> Bool {
        guard !isFirst else { return false }
        page -= 1
        return true
    }

    public static func letter(_ index: Int) -> String {
        String(Character(UnicodeScalar(UInt8(ascii: "A") + UInt8(index % 26))))
    }

    public static func choiceIndex(forLetter letter: Character) -> Int? {
        guard let scalar = letter.uppercased().unicodeScalars.first, scalar.value >= 65, scalar.value <= 90 else { return nil }
        return Int(scalar.value) - 65
    }
}
