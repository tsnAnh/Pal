import Foundation
import PalProtocol
import PalTransport

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

    public enum Phase: Sendable, Equatable {
        case answering
        case sending
        case failed(String)
    }

    public enum Step: Sendable, Equatable {
        case ignored
        case stayed
        case advanced
        case submit
    }

    public let questions: [ClarifyQuestion]
    public private(set) var drafts: [Draft]
    public private(set) var page = 0
    public private(set) var phase = Phase.answering

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
    public var isSending: Bool { phase == .sending }
    public var advancesOnPick: Bool { hasChoices && !current.multiSelect }
    public var needsConfirm: Bool { !advancesOnPick }

    public var failure: String? {
        if case .failed(let reason) = phase { reason } else { nil }
    }

    public func canJump(to index: Int) -> Bool {
        !isSending && index != page && isAnswered(index)
    }

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
        guard !isSending, current.choices.indices.contains(index) else { return }
        resumeAnswering()
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
        guard !isSending else { return }
        resumeAnswering()
        var draft = drafts[page]
        draft.typed = text
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft.skipped = false
            if !current.multiSelect { draft.picked = [] }
        }
        drafts[page] = draft
    }

    public mutating func skip() {
        guard !isSending else { return }
        resumeAnswering()
        drafts[page] = Draft(skipped: true)
    }

    @discardableResult
    public mutating func advance() -> Bool {
        guard !isSending, canAdvance, !isLast else { return false }
        page += 1
        return true
    }

    @discardableResult
    public mutating func back() -> Bool {
        guard !isSending, !isFirst else { return false }
        resumeAnswering()
        page -= 1
        return true
    }

    @discardableResult
    public mutating func jump(to index: Int) -> Bool {
        guard canJump(to: index) else { return false }
        resumeAnswering()
        page = index
        return true
    }

    @discardableResult
    public mutating func choose(_ index: Int) -> Step {
        guard !isSending, current.choices.indices.contains(index) else { return .ignored }
        pick(index)
        return advancesOnPick ? move() : .stayed
    }

    @discardableResult
    public mutating func confirm() -> Step {
        guard !isSending, canAdvance else { return .ignored }
        return move()
    }

    @discardableResult
    public mutating func skipPage() -> Step {
        guard !isSending else { return .ignored }
        skip()
        return move()
    }

    @discardableResult
    public mutating func retry() -> Step {
        guard case .failed = phase, canSubmit else { return .ignored }
        phase = .sending
        return .submit
    }

    public mutating func submitFailed(_ error: Error) {
        guard isSending else { return }
        page = count - 1
        phase = .failed(Self.failureReason(for: error))
    }

    private mutating func move() -> Step {
        resumeAnswering()
        guard isLast else {
            page += 1
            return .advanced
        }
        guard canSubmit else { return .stayed }
        phase = .sending
        return .submit
    }

    private mutating func resumeAnswering() {
        if case .failed = phase { phase = .answering }
    }

    public static func failureReason(for error: Error) -> String {
        switch error {
        case ChatError.notConnected:
            "Pal is not connected right now."
        case ChatError.clarifyExpired:
            "This question is no longer waiting for an answer."
        case let rpc as RPCError:
            rpc.message
        case GatewayTransportError.rpc(let rpc):
            rpc.message
        case let url as URLError where url.code == .notConnectedToInternet:
            "You are offline."
        default:
            error.localizedDescription
        }
    }

    public static func letter(_ index: Int) -> String {
        String(Character(UnicodeScalar(UInt8(ascii: "A") + UInt8(index % 26))))
    }

    public static func choiceIndex(forLetter letter: Character) -> Int? {
        guard let scalar = letter.uppercased().unicodeScalars.first, scalar.value >= 65, scalar.value <= 90 else { return nil }
        return Int(scalar.value) - 65
    }
}
