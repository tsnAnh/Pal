public enum CreateBotGate: Equatable, Sendable {
    case ready
    case creating
    case needsName
    case pickAnotherName

    public init(identity: BotIdentity, nameRefused: Bool, isCreating: Bool) {
        if isCreating {
            self = .creating
        } else if identity.displayName.isEmpty {
            self = .needsName
        } else if !identity.isValid || nameRefused {
            self = .pickAnotherName
        } else {
            self = .ready
        }
    }

    public var canCreate: Bool { self == .ready }
}
