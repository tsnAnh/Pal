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
        let items = TranscriptVisibility.visible(items)
        let dates = items.map(date)
        let separators = separators(for: dates, calendar: calendar)
        var dividerPlaced = false
        return items.enumerated().map { index, item in
            let itemDate = dates[index]
            var showsDivider = false
            if !dividerPlaced, let lastSeen, let itemDate, itemDate > lastSeen, isIncoming(item) {
                showsDivider = true
                dividerPlaced = true
            }
            return TimelineEntry(item: item, date: itemDate, separator: separators[index], showsNewDivider: showsDivider)
        }
    }

    public static func separators(for dates: [Date?], calendar: Calendar = .current) -> [Date?] {
        var previousDate: Date?
        return dates.map { itemDate in
            guard let itemDate else { return nil }
            defer { previousDate = itemDate }
            guard let previousDate else { return itemDate }
            let gap = itemDate.timeIntervalSince(previousDate)
            return gap >= separatorGap || !calendar.isDate(itemDate, inSameDayAs: previousDate) ? itemDate : nil
        }
    }

    private static func isIncoming(_ item: TranscriptItem) -> Bool {
        switch item.content {
        case .user: !item.inbound.isPerson
        case .assistant: true
        case .botThread(let link): link.kind == .messageFrom
        case .tool, .clarifyAnswered, .clarify, .approval: false
        }
    }
}
