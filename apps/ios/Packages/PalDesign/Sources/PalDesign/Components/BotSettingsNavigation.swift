public struct BotSettingsNavigation: Equatable, Sendable {
    public enum Event: Sendable {
        case escape
        case closeButton
        case backButton
    }

    public enum Exit: Equatable, Sendable {
        case back
        case close
    }

    public let depth: Int

    public init(depth: Int) {
        self.depth = max(0, depth)
    }

    public var isNested: Bool { depth > 0 }
    public var showsBack: Bool { isNested }
    public var escapeExit: Exit { isNested ? .back : .close }

    public func exit(for event: Event) -> Exit {
        switch event {
        case .escape: escapeExit
        case .closeButton: .close
        case .backButton: isNested ? .back : .close
        }
    }
}
