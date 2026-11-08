import Foundation
import HermesProtocol

public struct BotThreadEntry: Sendable, Hashable, Identifiable {
    public var message: BotThreadMessage
    public var separator: Date?
    public var showsName: Bool
    public var showsAvatar: Bool

    public var id: String { message.id }
}

public struct BotThreadTimeline: Sendable, Equatable {
    public private(set) var threadID: String
    public private(set) var participants: [BotThreadParticipant] = []
    public private(set) var messages: [BotThreadMessage] = []
    public private(set) var olderCursor: Int?
    public private(set) var newerCursor: Int?
    public private(set) var revision = 0
    public private(set) var isOwnSideOnly = false
    public private(set) var focusMessageID: String?

    public init(threadID: String) {
        self.threadID = threadID
    }

    public var hasOlder: Bool { olderCursor != nil }
    public var hasNewer: Bool { newerCursor != nil }

    public func entries(calendar: Calendar = .current) -> [BotThreadEntry] {
        let separators = ChatTimeline.separators(for: messages.map { Optional($0.at) }, calendar: calendar)
        return messages.indices.map { index in
            let message = messages[index]
            let startsRun = index == 0 || separators[index] != nil || messages[index - 1].senderKey != message.senderKey
            let endsRun = index == messages.count - 1 || separators[index + 1] != nil
                || messages[index + 1].senderKey != message.senderKey
            return BotThreadEntry(message: message, separator: separators[index], showsName: startsRun, showsAvatar: endsRun)
        }
    }

    public func participant(forSender key: String) -> BotThreadParticipant? {
        participants.first { $0.key == key }
    }

    public mutating func apply(initial page: BotThreadPage) {
        participants = page.participants
        messages = []
        merge(page.messages)
        olderCursor = page.before
        newerCursor = page.after
        revision = page.rev
        isOwnSideOnly = page.isOwnSideOnly
        if let index = page.focusIndex, page.messages.indices.contains(index) {
            focusMessageID = page.messages[index].id
        } else {
            focusMessageID = nil
        }
    }

    public mutating func apply(older page: BotThreadPage) {
        merge(page.messages)
        olderCursor = page.before
        revision = max(revision, page.rev)
    }

    public mutating func apply(newer page: BotThreadPage) {
        merge(page.messages)
        newerCursor = page.after
        revision = max(revision, page.rev)
    }

    public mutating func apply(delta page: BotThreadPage) {
        if !page.participants.isEmpty { participants = page.participants }
        if hasNewer {
            let known = Set(messages.map(\.id))
            merge(page.messages.filter { known.contains($0.id) })
        } else {
            merge(page.messages)
        }
        revision = max(revision, page.rev)
        isOwnSideOnly = page.isOwnSideOnly
    }

    private mutating func merge(_ incoming: [BotThreadMessage]) {
        var byID = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        for message in incoming { byID[message.id] = message }
        messages = byID.values.sorted { lhs, rhs in
            if lhs.at != rhs.at { return lhs.at < rhs.at }
            return (lhs.sequence ?? 0) < (rhs.sequence ?? 0)
        }
    }
}
