import Foundation
import os

@MainActor
final class ChatTimestampCache {
    static let shared = ChatTimestampCache()

    private static let capacity = 1024

    private static let invalidations: [Notification.Name] = [
        NSLocale.currentLocaleDidChangeNotification,
        .NSSystemTimeZoneDidChange,
        .NSCalendarDayChanged,
        .NSSystemClockDidChange,
    ]

    private let epoch = OSAllocatedUnfairLock(initialState: 0)
    private var seenEpoch = 0
    private var expires = Date.distantPast
    private var labels: [Date: String] = [:]

    private init() {
        for name in Self.invalidations {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [epoch] _ in
                epoch.withLock { $0 += 1 }
            }
        }
    }

    func label(for date: Date) -> String {
        let now = Date()
        let current = epoch.withLock { $0 }
        if current != seenEpoch || now >= expires {
            seenEpoch = current
            labels.removeAll(keepingCapacity: true)
            expires = Self.nextMidnight(after: now)
        }
        if let hit = labels[date] { return hit }
        let made = ChatTimestamp.label(for: date, now: now)
        if labels.count >= Self.capacity { labels.removeAll(keepingCapacity: true) }
        labels[date] = made
        return made
    }

    private static func nextMidnight(after now: Date) -> Date {
        Calendar.current.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0, second: 0), matchingPolicy: .nextTime) ?? .distantPast
    }
}
