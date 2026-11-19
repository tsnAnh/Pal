import Foundation

public struct ClarifyQuestion: Codable, Sendable, Hashable {
    public var qid: String
    public var question: String
    public var choices: [String]
    public var multiSelect: Bool

    public init(qid: String, question: String, choices: [String] = [], multiSelect: Bool = false) {
        self.qid = qid
        self.question = question
        self.choices = choices
        self.multiSelect = multiSelect
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        qid = try container.decode(String.self, forKey: .qid)
        question = try container.decode(String.self, forKey: .question)
        choices = try container.decodeIfPresent([String].self, forKey: .choices) ?? []
        multiSelect = try container.decodeIfPresent(Bool.self, forKey: .multiSelect) ?? false
    }

    enum CodingKeys: String, CodingKey {
        case qid
        case question
        case choices
        case multiSelect = "multi_select"
    }
}

struct ClarifyBatchParams: Decodable {
    var sessionID: String?
    var questions: [ClarifyQuestion]

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case questions
    }
}

extension PendingPrompt {
    public static let clarifyRequestMethod = "clarify"
    public static let requestCancelEvent = "request.cancel"
    public static let requestIDPrefix = "srq-"
    public static let soleQuestionID = "q0"

    public var isBatch: Bool { !questions.isEmpty }
    public var isForm: Bool { questions.count > 1 }

    public static func clarifyBatch(requestID: String, params: JSONValue?, sessionID: String?) -> PendingPrompt? {
        guard let params, let wire = try? params.decoded(as: ClarifyBatchParams.self), !wire.questions.isEmpty else { return nil }
        if let sessionID, let requested = wire.sessionID, requested != sessionID { return nil }
        let first = wire.questions[0]
        return PendingPrompt(
            kind: .clarify,
            promptID: requestID,
            executionGeneration: 0,
            choices: first.choices,
            question: first.question,
            multiSelect: first.multiSelect,
            questions: wire.questions
        )
    }
}
