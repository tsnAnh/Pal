import Foundation

public struct ClarifyRecord: Sendable, Hashable {
    public enum Answer: Sendable, Hashable {
        case answered([String])
        case skipped
    }

    public var question: String
    public var answer: Answer

    public init(question: String, answer: Answer) {
        self.question = question
        self.answer = answer
    }

    var summaryText: String {
        switch answer {
        case .answered(let picks): "\(question) -> \(picks.joined(separator: ", "))"
        case .skipped: "\(question) -> skipped"
        }
    }
}

struct ClarifyResult: Decodable {
    struct Response: Decodable {
        enum Status: String, Decodable {
            case answered
            case skipped
            case unanswered
        }

        let question: String
        let status: Status
        let userResponse: [String]?

        enum CodingKeys: String, CodingKey {
            case question
            case status
            case userResponse = "user_response"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            question = try container.decode(String.self, forKey: .question)
            status = try container.decode(Status.self, forKey: .status)
            if let many = try? container.decodeIfPresent([String].self, forKey: .userResponse) {
                userResponse = many
            } else if let one = try? container.decodeIfPresent(String.self, forKey: .userResponse) {
                userResponse = [one]
            } else {
                userResponse = nil
            }
        }

        var record: ClarifyRecord {
            let picks = (userResponse ?? []).filter { !$0.isEmpty }
            guard status == .answered, !picks.isEmpty else { return ClarifyRecord(question: question, answer: .skipped) }
            return ClarifyRecord(question: question, answer: .answered(picks))
        }
    }

    let responses: [Response]

    init?(json: String?) {
        guard let data = json?.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(ClarifyResult.self, from: data),
              !decoded.responses.isEmpty
        else { return nil }
        self = decoded
    }

    var records: [ClarifyRecord] { responses.map(\.record) }
}
