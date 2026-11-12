import Foundation
import PalProtocol

public enum DeviceProviderError: Error, Sendable, Equatable {
    case permissionDenied
    case accessDenied(String)
    case notFound
    case unsupported
    case invalidArgs(String)
    case failed(String)
}

public enum Weekday: String, Sendable, CaseIterable, Hashable {
    case mon, tue, wed, thu, fri, sat, sun

    public var calendarNumber: Int {
        switch self {
        case .sun: 1
        case .mon: 2
        case .tue: 3
        case .wed: 4
        case .thu: 5
        case .fri: 6
        case .sat: 7
        }
    }

    public init?(calendarNumber: Int) {
        guard let match = Self.allCases.first(where: { $0.calendarNumber == calendarNumber }) else { return nil }
        self = match
    }
}

public enum ReminderPriority: String, Sendable, Hashable {
    case none, low, medium, high
}

public struct CalendarEventRecord: Sendable, Equatable {
    public var id: String
    public var title: String
    public var start: Date
    public var end: Date?
    public var isAllDay: Bool
    public var location: String?
    public var calendar: String?
    public var notes: String?

    public init(id: String, title: String, start: Date, end: Date? = nil, isAllDay: Bool = false, location: String? = nil, calendar: String? = nil, notes: String? = nil) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.location = location
        self.calendar = calendar
        self.notes = notes
    }
}

public struct CalendarEventDraft: Sendable, Equatable {
    public var title: String
    public var start: Date
    public var end: Date?
    public var isAllDay: Bool
    public var location: String?
    public var notes: String?
    public var calendar: String?
    public var alertMinutesBefore: Int?

    public init(title: String, start: Date, end: Date? = nil, isAllDay: Bool = false, location: String? = nil, notes: String? = nil, calendar: String? = nil, alertMinutesBefore: Int? = nil) {
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.location = location
        self.notes = notes
        self.calendar = calendar
        self.alertMinutesBefore = alertMinutesBefore
    }
}

public protocol CalendarProviding: Sendable {
    func events(from start: Date, to end: Date, limit: Int) async throws -> [CalendarEventRecord]
    func add(_ draft: CalendarEventDraft) async throws -> CalendarEventRecord
}

public struct ReminderRecord: Sendable, Equatable {
    public var id: String
    public var title: String
    public var due: Date?
    public var isCompleted: Bool
    public var list: String?
    public var notes: String?
    public var priority: ReminderPriority

    public init(id: String, title: String, due: Date? = nil, isCompleted: Bool = false, list: String? = nil, notes: String? = nil, priority: ReminderPriority = .none) {
        self.id = id
        self.title = title
        self.due = due
        self.isCompleted = isCompleted
        self.list = list
        self.notes = notes
        self.priority = priority
    }
}

public struct ReminderDraft: Sendable, Equatable {
    public var title: String
    public var due: Date?
    public var notes: String?
    public var list: String?
    public var priority: ReminderPriority

    public init(title: String, due: Date? = nil, notes: String? = nil, list: String? = nil, priority: ReminderPriority = .none) {
        self.title = title
        self.due = due
        self.notes = notes
        self.list = list
        self.priority = priority
    }
}

public protocol RemindersProviding: Sendable {
    func list(named list: String?, includeCompleted: Bool, limit: Int) async throws -> [ReminderRecord]
    func add(_ draft: ReminderDraft) async throws -> ReminderRecord
    func complete(id: String) async throws -> ReminderRecord
}

public struct ContactRecord: Sendable, Equatable {
    public var id: String
    public var name: String
    public var organization: String?
    public var phones: [String]
    public var emails: [String]

    public init(id: String, name: String, organization: String? = nil, phones: [String] = [], emails: [String] = []) {
        self.id = id
        self.name = name
        self.organization = organization
        self.phones = phones
        self.emails = emails
    }
}

public protocol ContactsProviding: Sendable {
    func search(_ query: String, limit: Int) async throws -> [ContactRecord]
}

public struct LocationFix: Sendable, Equatable {
    public var latitude: Double
    public var longitude: Double
    public var accuracyMeters: Double?
    public var place: String?
    public var timestamp: Date?

    public init(latitude: Double, longitude: Double, accuracyMeters: Double? = nil, place: String? = nil, timestamp: Date? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.accuracyMeters = accuracyMeters
        self.place = place
        self.timestamp = timestamp
    }
}

public struct PlaceRecord: Sendable, Equatable {
    public var name: String
    public var address: String?
    public var latitude: Double
    public var longitude: Double
    public var distanceMeters: Double?
    public var category: String?
    public var phone: String?

    public init(name: String, address: String? = nil, latitude: Double, longitude: Double, distanceMeters: Double? = nil, category: String? = nil, phone: String? = nil) {
        self.name = name
        self.address = address
        self.latitude = latitude
        self.longitude = longitude
        self.distanceMeters = distanceMeters
        self.category = category
        self.phone = phone
    }
}

public protocol LocationProviding: Sendable {
    func current(precise: Bool) async throws -> LocationFix
    func searchNearby(_ query: String, radiusMeters: Int, limit: Int) async throws -> [PlaceRecord]
}

public struct AlarmRecord: Sendable, Equatable {
    public var id: String
    public var label: String?
    public var at: Date
    public var isEnabled: Bool
    public var repeatWeekdays: [Weekday]

    public init(id: String, label: String? = nil, at: Date, isEnabled: Bool = true, repeatWeekdays: [Weekday] = []) {
        self.id = id
        self.label = label
        self.at = at
        self.isEnabled = isEnabled
        self.repeatWeekdays = repeatWeekdays
    }
}

public struct TimerRecord: Sendable, Equatable {
    public var id: String
    public var label: String?
    public var seconds: Int
    public var endsAt: Date

    public init(id: String, label: String? = nil, seconds: Int, endsAt: Date) {
        self.id = id
        self.label = label
        self.seconds = seconds
        self.endsAt = endsAt
    }
}

public protocol AlarmsProviding: Sendable {
    func setAlarm(at: Date, label: String?, repeatWeekdays: [Weekday]) async throws -> AlarmRecord
    func alarms() async throws -> [AlarmRecord]
    func startTimer(seconds: Int, label: String?) async throws -> TimerRecord
}

public struct AccessoryRecord: Sendable, Equatable {
    public var id: String
    public var name: String
    public var room: String?
    public var category: String?
    public var isReachable: Bool
    public var state: [String: JSONValue]

    public init(id: String, name: String, room: String? = nil, category: String? = nil, isReachable: Bool = true, state: [String: JSONValue] = [:]) {
        self.id = id
        self.name = name
        self.room = room
        self.category = category
        self.isReachable = isReachable
        self.state = state
    }
}

public enum HomeCharacteristic: String, Sendable, Hashable {
    case power
    case brightness
    case lock
    case targetTemperature = "target_temperature"
}

public protocol HomeProviding: Sendable {
    func accessories(inRoom room: String?) async throws -> [AccessoryRecord]
    func set(accessoryID: String, characteristic: HomeCharacteristic, value: JSONValue) async throws -> AccessoryRecord
}

public struct ShellRunRecord: Sendable, Equatable {
    public var exitCode: Int?
    public var stdout: CapturedText
    public var stderr: CapturedText
    public var timedOut: Bool

    public init(exitCode: Int?, stdout: CapturedText = CapturedText(), stderr: CapturedText = CapturedText(), timedOut: Bool = false) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }
}

public protocol ShellProviding: Sendable {
    func run(command: String, workingDirectory: String?, timeout: Duration, captureLimit: Int) async throws -> ShellRunRecord
}

public enum FileEntryKind: String, Sendable, Hashable {
    case file, directory, symlink, other
}

public struct FileEntryRecord: Sendable, Equatable {
    public var name: String
    public var kind: FileEntryKind
    public var sizeBytes: Int?
    public var modified: Date?

    public init(name: String, kind: FileEntryKind, sizeBytes: Int? = nil, modified: Date? = nil) {
        self.name = name
        self.kind = kind
        self.sizeBytes = sizeBytes
        self.modified = modified
    }
}

public struct FileReadRecord: Sendable, Equatable {
    public var path: String
    public var content: CapturedText
    public var sizeBytes: Int

    public init(path: String, content: CapturedText, sizeBytes: Int) {
        self.path = path
        self.content = content
        self.sizeBytes = sizeBytes
    }
}

public struct FileListRecord: Sendable, Equatable {
    public var path: String
    public var entries: [FileEntryRecord]
    public var truncated: Bool

    public init(path: String, entries: [FileEntryRecord], truncated: Bool = false) {
        self.path = path
        self.entries = entries
        self.truncated = truncated
    }
}

public struct FileWriteRecord: Sendable, Equatable {
    public var path: String
    public var bytesWritten: Int

    public init(path: String, bytesWritten: Int) {
        self.path = path
        self.bytesWritten = bytesWritten
    }
}

public protocol FilesProviding: Sendable {
    func read(path: String, captureLimit: Int) async throws -> FileReadRecord
    func list(path: String, limit: Int) async throws -> FileListRecord
    func write(path: String, content: String, append: Bool, createDirs: Bool) async throws -> FileWriteRecord
}

public struct InputDisplayRecord: Sendable, Equatable {
    public var id: Int
    public var name: String?
    public var isMain: Bool
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var scale: Double

    public init(id: Int, name: String? = nil, isMain: Bool, x: Double, y: Double, width: Double, height: Double, scale: Double) {
        self.id = id
        self.name = name
        self.isMain = isMain
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.scale = scale
    }

    public func contains(x px: Double, y py: Double) -> Bool {
        px >= x && px < x + width && py >= y && py < y + height
    }
}

public struct InputDisplaysRecord: Sendable, Equatable {
    public var displays: [InputDisplayRecord]
    public var pointerX: Double
    public var pointerY: Double

    public init(displays: [InputDisplayRecord], pointerX: Double, pointerY: Double) {
        self.displays = displays
        self.pointerX = pointerX
        self.pointerY = pointerY
    }
}

public struct InputPostRecord: Sendable, Equatable {
    public var events: Int
    public var pointerX: Double?
    public var pointerY: Double?

    public init(events: Int, pointerX: Double? = nil, pointerY: Double? = nil) {
        self.events = events
        self.pointerX = pointerX
        self.pointerY = pointerY
    }
}

public struct InputPoint: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var display: Int?

    public init(x: Double, y: Double, display: Int? = nil) {
        self.x = x
        self.y = y
        self.display = display
    }
}

public enum InputButton: String, Sendable, Hashable {
    case left, right, middle
}

public enum InputMoveTarget: Sendable, Equatable {
    case absolute(InputPoint)
    case relative(dx: Double, dy: Double)
}

public protocol InputProviding: Sendable {
    func displays() async throws -> InputDisplaysRecord
    func move(_ target: InputMoveTarget) async throws -> InputPostRecord
    func click(at point: InputPoint?, button: InputButton, clicks: Int) async throws -> InputPostRecord
    func drag(from: InputPoint, to: InputPoint, button: InputButton) async throws -> InputPostRecord
    func scroll(at point: InputPoint?, dx: Int, dy: Int) async throws -> InputPostRecord
    func type(_ text: String) async throws -> InputPostRecord
    func press(key: String) async throws -> InputPostRecord
}

public struct DeviceProviders: Sendable {
    public var calendar: (any CalendarProviding)?
    public var reminders: (any RemindersProviding)?
    public var contacts: (any ContactsProviding)?
    public var location: (any LocationProviding)?
    public var alarms: (any AlarmsProviding)?
    public var home: (any HomeProviding)?
    public var shell: (any ShellProviding)?
    public var files: (any FilesProviding)?
    public var input: (any InputProviding)?

    public init(
        calendar: (any CalendarProviding)? = nil,
        reminders: (any RemindersProviding)? = nil,
        contacts: (any ContactsProviding)? = nil,
        location: (any LocationProviding)? = nil,
        alarms: (any AlarmsProviding)? = nil,
        home: (any HomeProviding)? = nil,
        shell: (any ShellProviding)? = nil,
        files: (any FilesProviding)? = nil,
        input: (any InputProviding)? = nil
    ) {
        self.calendar = calendar
        self.reminders = reminders
        self.contacts = contacts
        self.location = location
        self.alarms = alarms
        self.home = home
        self.shell = shell
        self.files = files
        self.input = input
    }
}

public protocol DevicePermissions: Sendable {
    func status(of connector: DeviceConnectorID) async -> DeviceOSPermission
    func request(_ connector: DeviceConnectorID) async -> DeviceOSPermission
}

public struct ConsentAsk: Sendable, Equatable {
    public var connector: DeviceConnectorID
    public var action: DeviceToolAction
    public var profile: String

    public init(connector: DeviceConnectorID, action: DeviceToolAction, profile: String) {
        self.connector = connector
        self.action = action
        self.profile = profile
    }
}

public protocol ConsentPrompting: Sendable {
    func askConsent(_ ask: ConsentAsk) async -> Bool
}
