import Foundation

public enum MessageAction: String, Sendable, CaseIterable {
    case reply
    case markUnread
    case markRead
    case copy
    case selectText
    case share
    case speak
    case retry
    case copyTable
}

public struct MessageActionPlan: Equatable, Sendable {
    public let groups: [[MessageAction]]

    public init(isOwnFailed: Bool, hasTable: Bool, isChatUnread: Bool, offersSelectText: Bool) {
        if isOwnFailed {
            groups = [[.retry], Self.copyGroup(hasTable: hasTable, offersSelectText: offersSelectText)]
            return
        }
        groups = [
            [.reply, isChatUnread ? .markRead : .markUnread],
            Self.copyGroup(hasTable: hasTable, offersSelectText: offersSelectText),
            [.share, .speak],
        ]
    }

    public var actions: [MessageAction] { groups.flatMap { $0 } }

    private static func copyGroup(hasTable: Bool, offersSelectText: Bool) -> [MessageAction] {
        [.copy] + (offersSelectText ? [.selectText] : []) + (hasTable ? [.copyTable] : [])
    }
}
