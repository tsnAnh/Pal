import EventKit
import Foundation

public actor EventKitCalendar: CalendarProviding {
    private let store = EKEventStore()

    public init() {}

    public func events(from start: Date, to end: Date, limit: Int) async throws -> [CalendarEventRecord] {
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .prefix(limit)
            .map(Self.record)
    }

    public func add(_ draft: CalendarEventDraft) async throws -> CalendarEventRecord {
        let event = EKEvent(eventStore: store)
        event.title = draft.title
        event.startDate = draft.start
        event.isAllDay = draft.isAllDay
        event.endDate = draft.end ?? (draft.isAllDay ? draft.start : draft.start.addingTimeInterval(3600))
        event.location = draft.location
        event.notes = draft.notes
        guard let calendar = writableCalendar(named: draft.calendar) else { throw DeviceProviderError.notFound }
        event.calendar = calendar
        if let minutes = draft.alertMinutesBefore { event.addAlarm(EKAlarm(relativeOffset: -TimeInterval(minutes) * 60)) }
        do { try store.save(event, span: .thisEvent) } catch { throw DeviceProviderError.failed("The event could not be saved.") }
        return Self.record(event)
    }

    private func writableCalendar(named name: String?) -> EKCalendar? {
        if let name, let match = store.calendars(for: .event).first(where: { $0.title == name && $0.allowsContentModifications }) { return match }
        if name != nil { return nil }
        return store.defaultCalendarForNewEvents
    }

    private static func record(_ event: EKEvent) -> CalendarEventRecord {
        CalendarEventRecord(
            id: event.eventIdentifier ?? UUID().uuidString, title: event.title ?? "", start: event.startDate, end: event.endDate,
            isAllDay: event.isAllDay, location: event.location, calendar: event.calendar?.title, notes: event.notes
        )
    }
}

public actor EventKitReminders: RemindersProviding {
    private let store = EKEventStore()

    public init() {}

    public func list(named list: String?, includeCompleted: Bool, limit: Int) async throws -> [ReminderRecord] {
        let calendars = try list.map { name -> [EKCalendar] in
            let match = store.calendars(for: .reminder).filter { $0.title == name }
            guard !match.isEmpty else { throw DeviceProviderError.notFound }
            return match
        }
        let predicate = store.predicateForReminders(in: calendars)
        let fetched = await fetch(predicate)
        return fetched
            .filter { includeCompleted || !$0.isCompleted }
            .sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
            .prefix(limit)
            .map { $0 }
    }

    public func add(_ draft: ReminderDraft) async throws -> ReminderRecord {
        let reminder = EKReminder(eventStore: store)
        reminder.title = draft.title
        reminder.notes = draft.notes
        reminder.priority = Self.priorityValue(draft.priority)
        if let due = draft.due {
            reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second, .timeZone], from: due)
        }
        if let name = draft.list {
            guard let match = store.calendars(for: .reminder).first(where: { $0.title == name && $0.allowsContentModifications }) else { throw DeviceProviderError.notFound }
            reminder.calendar = match
        } else {
            guard let fallback = store.defaultCalendarForNewReminders() else { throw DeviceProviderError.failed("There is no list to add the reminder to.") }
            reminder.calendar = fallback
        }
        do { try store.save(reminder, commit: true) } catch { throw DeviceProviderError.failed("The reminder could not be saved.") }
        return Self.record(reminder)
    }

    public func complete(id: String) async throws -> ReminderRecord {
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { throw DeviceProviderError.notFound }
        reminder.isCompleted = true
        do { try store.save(reminder, commit: true) } catch { throw DeviceProviderError.failed("The reminder could not be updated.") }
        return Self.record(reminder)
    }

    private func fetch(_ predicate: NSPredicate) async -> [ReminderRecord] {
        await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: (reminders ?? []).map(Self.record))
            }
        }
    }

    private static func priorityValue(_ priority: ReminderPriority) -> Int {
        switch priority {
        case .none: 0
        case .high: 1
        case .medium: 5
        case .low: 9
        }
    }

    private static func priority(from value: Int) -> ReminderPriority {
        switch value {
        case 1...4: .high
        case 5: .medium
        case 6...9: .low
        default: .none
        }
    }

    private static func record(_ reminder: EKReminder) -> ReminderRecord {
        ReminderRecord(
            id: reminder.calendarItemIdentifier, title: reminder.title ?? "",
            due: reminder.dueDateComponents.flatMap { ($0.calendar ?? Calendar.current).date(from: $0) },
            isCompleted: reminder.isCompleted, list: reminder.calendar?.title, notes: reminder.notes,
            priority: priority(from: reminder.priority)
        )
    }
}
