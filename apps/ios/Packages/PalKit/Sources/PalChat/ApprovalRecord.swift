import PalProtocol

public struct ApprovalRecord: Sendable, Hashable {
    public enum Decision: String, Sendable, Hashable {
        case once
        case session
        case always
        case deny
    }

    public var request: String
    public var decision: Decision?

    public init(request: String, decision: Decision?) {
        self.request = request
        self.decision = decision
    }

    init(prompt: PendingPrompt, choice: String?) {
        request = prompt.description ?? prompt.command ?? ""
        decision = choice.flatMap(Decision.init(rawValue:))
    }
}
