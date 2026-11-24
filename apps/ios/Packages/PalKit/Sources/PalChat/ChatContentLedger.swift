import Foundation

public enum ChatContentSource: String, Sendable, Equatable {
    case none
    case rows
    case inset
    case streamingGrowth = "streaming-growth"
    case estimateReplaced = "estimate-replaced"
}

public struct ChatContentLedger: Sendable, Equatable {
    public static let movedThreshold = 0.5
    public static let rowsLifetime = 3

    private var rowsPending = false
    private var streaming = false
    private var quietEvents = 0

    public init() {}

    public mutating func noteRows() {
        rowsPending = true
        quietEvents = 0
    }

    public mutating func noteStreaming(_ value: Bool) {
        streaming = value
    }

    public mutating func attribute(from previous: ChatScrollGeometry?, to current: ChatScrollGeometry) -> ChatContentSource {
        guard let previous, abs(current.contentHeight - previous.contentHeight) > Self.movedThreshold else {
            quietEvents += 1
            if quietEvents >= Self.rowsLifetime { rowsPending = false }
            return .none
        }
        defer { rowsPending = false }
        let boxChanged = abs(current.containerHeight - previous.containerHeight) > Self.movedThreshold
            || abs(current.containerWidth - previous.containerWidth) > Self.movedThreshold
            || abs(current.insetTop - previous.insetTop) > Self.movedThreshold
            || abs(current.insetBottom - previous.insetBottom) > Self.movedThreshold
        if boxChanged { return .inset }
        if rowsPending { return .rows }
        return streaming ? .streamingGrowth : .estimateReplaced
    }
}
