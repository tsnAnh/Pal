import Foundation

public enum ChatScrollWriter: String, Sendable, Equatable {
    case none
    case user
    case machineScrollToBottom = "machine:scrollToBottom"
    case machineScrollToRow = "machine:scrollToRow"
    case machineRestore = "machine:restore"
    case systemAnchor = "system-anchor"
    case unattributed
}

public struct ChatScrollWriterLedger: Sendable, Equatable {
    public static let movedThreshold = 0.01
    public static let writeLifetime = 3

    private var pending: ChatScrollWriter?
    private var quietEvents = 0

    public init() {}

    public mutating func noteWrite(_ command: ChatScrollMachine.Command) {
        switch command {
        case .none: return
        case .scrollToBottom: pending = .machineScrollToBottom
        case .scrollToRow: pending = .machineScrollToRow
        case .restore: pending = .machineRestore
        }
        quietEvents = 0
    }

    public mutating func attribute(
        from previous: ChatScrollGeometry?,
        to current: ChatScrollGeometry,
        userMoving: Bool
    ) -> ChatScrollWriter {
        guard let previous, abs(current.offsetY - previous.offsetY) > Self.movedThreshold else {
            quietEvents += 1
            if quietEvents >= Self.writeLifetime { pending = nil }
            return .none
        }
        let machine = pending
        pending = nil
        if userMoving { return .user }
        if let machine { return machine }
        return current.sameSize(as: previous) ? .unattributed : .systemAnchor
    }
}

public struct ChatScrollSample: Sendable, Equatable {
    public var geometry: ChatScrollGeometry
    public var state: String
    public var showsButton: Bool
    public var userScrolling: Bool
    public var phase: String
    public var writer: ChatScrollWriter
    public var offsetDelta: Double
    public var contentDelta: Double
    public var contentSource: ChatContentSource

    public init(
        geometry: ChatScrollGeometry,
        state: String,
        showsButton: Bool,
        userScrolling: Bool,
        phase: String,
        writer: ChatScrollWriter,
        offsetDelta: Double,
        contentDelta: Double = 0,
        contentSource: ChatContentSource = .none
    ) {
        self.geometry = geometry
        self.state = state
        self.showsButton = showsButton
        self.userScrolling = userScrolling
        self.phase = phase
        self.writer = writer
        self.offsetDelta = offsetDelta
        self.contentDelta = contentDelta
        self.contentSource = contentSource
    }

    public var isAtBottom: Bool { geometry.distanceFromBottom <= ChatScrollMachine.atBottomTolerance }
}
