import Foundation

public struct CalendarEventWire: Encodable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var start: String
    public var end: String?
    public var allDay: Bool
    public var location: String?
    public var calendar: String?
    public var notes: String?

    public init(id: String, title: String, start: String, end: String?, allDay: Bool, location: String?, calendar: String?, notes: String?) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.allDay = allDay
        self.location = location
        self.calendar = calendar
        self.notes = notes
    }
}

public struct ReminderWire: Encodable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var due: String?
    public var completed: Bool
    public var list: String?
    public var notes: String?
    public var priority: String

    public init(id: String, title: String, due: String?, completed: Bool, list: String?, notes: String?, priority: String) {
        self.id = id
        self.title = title
        self.due = due
        self.completed = completed
        self.list = list
        self.notes = notes
        self.priority = priority
    }
}

public struct ContactWire: Encodable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var organization: String?
    public var phones: [String]
    public var emails: [String]

    public init(id: String, name: String, organization: String?, phones: [String], emails: [String]) {
        self.id = id
        self.name = name
        self.organization = organization
        self.phones = phones
        self.emails = emails
    }
}

public struct LocationWire: Encodable, Sendable, Equatable {
    public var latitude: Double
    public var longitude: Double
    public var accuracyMeters: Double?
    public var place: String?
    public var timestamp: String?

    public init(latitude: Double, longitude: Double, accuracyMeters: Double?, place: String?, timestamp: String?) {
        self.latitude = latitude
        self.longitude = longitude
        self.accuracyMeters = accuracyMeters
        self.place = place
        self.timestamp = timestamp
    }
}

public struct PlaceWire: Encodable, Sendable, Equatable {
    public var name: String
    public var address: String?
    public var latitude: Double
    public var longitude: Double
    public var distanceMeters: Double?
    public var category: String?
    public var phone: String?

    public init(name: String, address: String?, latitude: Double, longitude: Double, distanceMeters: Double?, category: String?, phone: String?) {
        self.name = name
        self.address = address
        self.latitude = latitude
        self.longitude = longitude
        self.distanceMeters = distanceMeters
        self.category = category
        self.phone = phone
    }
}

public struct AlarmWire: Encodable, Sendable, Equatable {
    public var id: String
    public var label: String?
    public var at: String
    public var enabled: Bool
    public var repeatWeekdays: [String]

    public init(id: String, label: String?, at: String, enabled: Bool, repeatWeekdays: [String]) {
        self.id = id
        self.label = label
        self.at = at
        self.enabled = enabled
        self.repeatWeekdays = repeatWeekdays
    }
}

public struct TimerWire: Encodable, Sendable, Equatable {
    public var id: String
    public var label: String?
    public var seconds: Int
    public var endsAt: String

    public init(id: String, label: String?, seconds: Int, endsAt: String) {
        self.id = id
        self.label = label
        self.seconds = seconds
        self.endsAt = endsAt
    }
}

public struct AccessoryWire: Encodable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var room: String?
    public var category: String?
    public var reachable: Bool
    public var state: [String: JSONValue]

    public init(id: String, name: String, room: String?, category: String?, reachable: Bool, state: [String: JSONValue]) {
        self.id = id
        self.name = name
        self.room = room
        self.category = category
        self.reachable = reachable
        self.state = state
    }
}
