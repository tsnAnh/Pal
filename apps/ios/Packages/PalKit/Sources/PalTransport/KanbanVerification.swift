public enum KanbanVerification: Sendable, Hashable, Codable {
    case independent
    case attested
    case unknown(String)

    public init(wire: String) {
        switch wire {
        case "independent": self = .independent
        case "attested": self = .attested
        default: self = .unknown(wire)
        }
    }
}
