import Foundation

public struct AbsorbedEchoLedger: Sendable, Equatable {
    public struct Pending: Sendable, Equatable {
        public let submissionID: String
        public let text: String

        public init(submissionID: String, text: String) {
            self.submissionID = submissionID
            self.text = text
        }
    }

    private var claims: [String: String] = [:]

    public init() {}

    public mutating func hiddenSubmissions(pending: [Pending], absorbed: [TranscriptItem]) -> Set<String> {
        var hidden: Set<String> = []
        for entry in pending {
            if absorbed.contains(where: { claims[$0.id] == entry.submissionID }) {
                hidden.insert(entry.submissionID)
            } else if let item = absorbed.first(where: { claims[$0.id] == nil && Self.text(of: $0) == entry.text }) {
                claims[item.id] = entry.submissionID
                hidden.insert(entry.submissionID)
            }
        }
        return hidden
    }

    private static func text(of item: TranscriptItem) -> String? {
        if case .user(let text, _) = item.content { text } else { nil }
    }
}
