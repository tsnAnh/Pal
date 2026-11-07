import Foundation

public struct TimelineEntry: Sendable, Hashable, Identifiable {
    public var item: TranscriptItem
    public var date: Date?
    public var separator: Date?
    public var showsNewDivider: Bool

    public var id: String { item.id }
}

public enum ChatTimeline {
    public static let separatorGap: TimeInterval = 5 * 60

    public static func entries(
        items: [TranscriptItem],
        date: (TranscriptItem) -> Date?,
        lastSeen: Date?,
        calendar: Calendar = .current
    ) -> [TimelineEntry] {
        var previousDate: Date?
        var dividerPlaced = false
        return items.map { item in
            let itemDate = date(item)
            var separator: Date?
            if let itemDate {
                if let previousDate {
                    let gap = itemDate.timeIntervalSince(previousDate)
                    if gap >= separatorGap || !calendar.isDate(itemDate, inSameDayAs: previousDate) { separator = itemDate }
                } else {
                    separator = itemDate
                }
                previousDate = itemDate
            }
            var showsDivider = false
            if !dividerPlaced, let lastSeen, let itemDate, itemDate > lastSeen, isIncoming(item) {
                showsDivider = true
                dividerPlaced = true
            }
            return TimelineEntry(item: item, date: itemDate, separator: separator, showsNewDivider: showsDivider)
        }
    }

    public static func newestDate(items: [TranscriptItem], date: (TranscriptItem) -> Date?) -> Date? {
        items.compactMap(date).max()
    }

    private static func isIncoming(_ item: TranscriptItem) -> Bool {
        switch item.content {
        case .user: !item.inbound.isPerson
        case .assistant: true
        case .tool, .clarify, .approval: false
        }
    }
}
