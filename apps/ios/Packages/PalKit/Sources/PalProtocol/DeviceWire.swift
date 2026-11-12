import Foundation

public enum DeviceConnectorID: String, Codable, Sendable, Hashable, CaseIterable {
    case calendar
    case home
    case reminders
    case contacts
    case location
    case alarms
    case shell
    case files
    case input

    public var needsOSPermission: Bool {
        switch self {
        case .shell, .files: false
        case .calendar, .home, .reminders, .contacts, .location, .alarms, .input: true
        }
    }
}

public enum DeviceConnectorState: String, Codable, Sendable, Hashable {
    case allowed
    case ask
    case off

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .ask
    }

    public var isEnabled: Bool { self != .off }
}

public enum DeviceOSPermission: String, Codable, Sendable, Hashable {
    case granted
    case denied
    case notDetermined = "not_determined"
    case unsupported

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .notDetermined
    }
}

public struct DeviceConnectorStatus: Codable, Sendable, Hashable, Identifiable {
    public var id: DeviceConnectorID
    public var title: String
    public var subtitle: String
    public var state: DeviceConnectorState
    public var osPermission: DeviceOSPermission

    public init(
        id: DeviceConnectorID,
        title: String,
        subtitle: String,
        state: DeviceConnectorState,
        osPermission: DeviceOSPermission
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.state = state
        self.osPermission = osPermission
    }

    enum CodingKeys: String, CodingKey {
        case id, title, subtitle, state
        case osPermission = "os_permission"
    }
}

public struct DeviceConnectorsResult: Sendable, Hashable, Decodable {
    public var deviceID: String
    public var connectors: [DeviceConnectorStatus]

    public init(deviceID: String, connectors: [DeviceConnectorStatus]) {
        self.deviceID = deviceID
        self.connectors = connectors
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deviceID = try container.decode(String.self, forKey: .deviceID)
        let rows = try container.decode([JSONValue].self, forKey: .connectors)
        connectors = rows.compactMap { try? $0.decoded(as: DeviceConnectorStatus.self) }
    }

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case connectors
    }
}

public enum DeviceToolAction: String, Codable, Sendable, Hashable, CaseIterable {
    case calendarListEvents = "calendar.list_events"
    case calendarAddEvent = "calendar.add_event"
    case remindersList = "reminders.list"
    case remindersAdd = "reminders.add"
    case remindersComplete = "reminders.complete"
    case contactsSearch = "contacts.search"
    case locationCurrent = "location.current"
    case locationSearchNearby = "location.search_nearby"
    case alarmsSet = "alarms.set"
    case alarmsList = "alarms.list"
    case timersStart = "timers.start"
    case homeListAccessories = "home.list_accessories"
    case homeSet = "home.set"
    case shellRun = "shell.run"
    case filesRead = "files.read"
    case filesList = "files.list"
    case filesWrite = "files.write"
    case inputDisplays = "input.displays"
    case inputMove = "input.move"
    case inputClick = "input.click"
    case inputDrag = "input.drag"
    case inputScroll = "input.scroll"
    case inputType = "input.type"
    case inputKey = "input.key"

    public var connector: DeviceConnectorID {
        switch self {
        case .calendarListEvents, .calendarAddEvent: .calendar
        case .remindersList, .remindersAdd, .remindersComplete: .reminders
        case .contactsSearch: .contacts
        case .locationCurrent, .locationSearchNearby: .location
        case .alarmsSet, .alarmsList, .timersStart: .alarms
        case .homeListAccessories, .homeSet: .home
        case .shellRun: .shell
        case .filesRead, .filesList, .filesWrite: .files
        case .inputDisplays, .inputMove, .inputClick, .inputDrag, .inputScroll, .inputType, .inputKey: .input
        }
    }
}

public enum DeviceToolErrorCode: String, Codable, Sendable, Hashable {
    case permissionDenied = "permission_denied"
    case consentDeclined = "consent_declined"
    case unsupported
    case invalidArgs = "invalid_args"
    case notFound = "not_found"
    case failed
}

public enum DeviceToolCancelReason: String, Sendable, Hashable {
    case timeout
    case interrupted
    case disconnected
}

public struct DeviceToolRequest: Sendable, Hashable {
    public static let eventType = "device.tool.request"
    public static let maximumErrorMessage = 300

    public var requestID: String
    public var action: String
    public var connector: String
    public var args: JSONValue
    public var needsConsent: Bool
    public var profile: String
    public var sessionID: String?
    public var deadlineSeconds: Int

    public init(
        requestID: String,
        action: String,
        connector: String,
        args: JSONValue = [:],
        needsConsent: Bool = false,
        profile: String = "default",
        sessionID: String? = nil,
        deadlineSeconds: Int = 30
    ) {
        self.requestID = requestID
        self.action = action
        self.connector = connector
        self.args = args
        self.needsConsent = needsConsent
        self.profile = profile
        self.sessionID = sessionID
        self.deadlineSeconds = deadlineSeconds
    }

    public init?(event: GatewayEvent) {
        guard event.type == Self.eventType, let payload = event.payload,
              let requestID = payload["request_id"]?.stringValue, !requestID.isEmpty,
              let action = payload["action"]?.stringValue,
              let connector = payload["connector"]?.stringValue
        else { return nil }
        self.init(
            requestID: requestID,
            action: action,
            connector: connector,
            args: payload["args"] ?? [:],
            needsConsent: payload["needs_consent"]?.boolValue ?? false,
            profile: payload["profile"]?.stringValue ?? "default",
            sessionID: payload["session_id"]?.stringValue,
            deadlineSeconds: payload["deadline_seconds"]?.intValue ?? 30
        )
    }
}

public struct DeviceToolCancel: Sendable, Hashable {
    public static let eventType = "device.tool.cancel"

    public var requestID: String
    public var reason: DeviceToolCancelReason?

    public init?(event: GatewayEvent) {
        guard event.type == Self.eventType, let id = event.payload?["request_id"]?.stringValue, !id.isEmpty else { return nil }
        requestID = id
        reason = event.payload?["reason"]?.stringValue.flatMap(DeviceToolCancelReason.init(rawValue:))
    }
}

public enum DeviceToolOutcome: Sendable, Hashable {
    case success(JSONValue)
    case failure(DeviceToolErrorCode, String)

    public func respondParams(requestID: String) -> JSONValue {
        switch self {
        case .success(let result):
            ["request_id": .string(requestID), "ok": true, "result": result]
        case .failure(let code, let message):
            [
                "request_id": .string(requestID),
                "ok": false,
                "error": ["code": .string(code.rawValue), "message": .string(String(message.prefix(DeviceToolRequest.maximumErrorMessage)))],
            ]
        }
    }
}

public enum DeviceWire {
    public static let helloCapability = "device_tools"

    public static func setConnectorParams(
        _ id: DeviceConnectorID,
        state: DeviceConnectorState? = nil,
        osPermission: DeviceOSPermission? = nil,
        deviceID: String? = nil
    ) -> JSONValue {
        var object: [String: JSONValue] = ["id": .string(id.rawValue)]
        if let state { object["state"] = .string(state.rawValue) }
        if let osPermission { object["os_permission"] = .string(osPermission.rawValue) }
        if let deviceID { object["device_id"] = .string(deviceID) }
        return .object(object)
    }

    public static func encode<T: Encodable>(_ value: T) throws -> JSONValue {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try JSONDecoder().decode(JSONValue.self, from: encoder.encode(value))
    }

    public static func decodeArgs<T: Decodable>(_ value: JSONValue, as type: T.Type = T.self) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try value.decoded(as: T.self, using: decoder)
    }
}

public struct CalendarListEventsArgs: Decodable, Sendable {
    public var start: String
    public var end: String
    public var limit: Int?
}

public struct CalendarAddEventArgs: Decodable, Sendable {
    public var title: String
    public var start: String
    public var end: String?
    public var allDay: Bool?
    public var location: String?
    public var notes: String?
    public var calendar: String?
    public var alertMinutesBefore: Int?
}

public struct RemindersListArgs: Decodable, Sendable {
    public var list: String?
    public var includeCompleted: Bool?
    public var limit: Int?
}

public struct RemindersAddArgs: Decodable, Sendable {
    public var title: String
    public var due: String?
    public var notes: String?
    public var list: String?
    public var priority: String?
}

public struct RemindersCompleteArgs: Decodable, Sendable {
    public var reminderId: String
}

public struct ContactsSearchArgs: Decodable, Sendable {
    public var query: String
    public var limit: Int?
}

public struct LocationCurrentArgs: Decodable, Sendable {
    public var accuracy: String?
}

public struct LocationSearchNearbyArgs: Decodable, Sendable {
    public var query: String
    public var radiusMeters: Int?
    public var limit: Int?
}

public struct AlarmsSetArgs: Decodable, Sendable {
    public var at: String
    public var label: String?
    public var repeatWeekdays: [String]?
}

public struct TimersStartArgs: Decodable, Sendable {
    public var seconds: Int
    public var label: String?
}

public struct HomeListAccessoriesArgs: Decodable, Sendable {
    public var room: String?
}

public struct HomeSetArgs: Decodable, Sendable {
    public var accessoryId: String
    public var characteristic: String
    public var value: JSONValue
}

public struct ShellRunArgs: Decodable, Sendable {
    public var command: String
    public var cwd: String?
    public var timeoutSeconds: Int?
}

public struct FilesReadArgs: Decodable, Sendable {
    public var path: String
}

public struct FilesListArgs: Decodable, Sendable {
    public var path: String
    public var limit: Int?
}

public struct FilesWriteArgs: Decodable, Sendable {
    public var path: String
    public var content: String
    public var append: Bool?
    public var createDirs: Bool?
}

public struct InputMoveArgs: Decodable, Sendable {
    public var x: Double?
    public var y: Double?
    public var dx: Double?
    public var dy: Double?
    public var display: Int?
}

public struct InputClickArgs: Decodable, Sendable {
    public var x: Double?
    public var y: Double?
    public var display: Int?
    public var button: String?
    public var clicks: Int?
}

public struct InputDragArgs: Decodable, Sendable {
    public var fromX: Double
    public var fromY: Double
    public var toX: Double
    public var toY: Double
    public var display: Int?
    public var button: String?
}

public struct InputScrollArgs: Decodable, Sendable {
    public var x: Double?
    public var y: Double?
    public var display: Int?
    public var dx: Int?
    public var dy: Int?
}

public struct InputTypeArgs: Decodable, Sendable {
    public var text: String
}

public struct InputKeyArgs: Decodable, Sendable {
    public var key: String
}

public struct InputDisplayWire: Encodable, Sendable, Equatable {
    public var id: Int
    public var name: String?
    public var main: Bool
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var scale: Double

    public init(id: Int, name: String?, main: Bool, x: Double, y: Double, width: Double, height: Double, scale: Double) {
        self.id = id
        self.name = name
        self.main = main
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.scale = scale
    }
}

public struct InputDisplaysWire: Encodable, Sendable, Equatable {
    public var displays: [InputDisplayWire]
    public var pointerX: Double
    public var pointerY: Double

    public init(displays: [InputDisplayWire], pointerX: Double, pointerY: Double) {
        self.displays = displays
        self.pointerX = pointerX
        self.pointerY = pointerY
    }
}

public struct InputResultWire: Encodable, Sendable, Equatable {
    public var events: Int
    public var pointerX: Double?
    public var pointerY: Double?

    public init(events: Int, pointerX: Double?, pointerY: Double?) {
        self.events = events
        self.pointerX = pointerX
        self.pointerY = pointerY
    }
}

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

public struct ShellRunWire: Encodable, Sendable, Equatable {
    public var exitCode: Int?
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool
    public var truncated: Bool

    public init(exitCode: Int?, stdout: String, stderr: String, timedOut: Bool, truncated: Bool) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
        self.truncated = truncated
    }

    enum CodingKeys: String, CodingKey {
        case exitCode, stdout, stderr, timedOut, truncated
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(exitCode, forKey: .exitCode)
        try container.encode(stdout, forKey: .stdout)
        try container.encode(stderr, forKey: .stderr)
        try container.encode(timedOut, forKey: .timedOut)
        try container.encode(truncated, forKey: .truncated)
    }
}

public struct FileReadWire: Encodable, Sendable, Equatable {
    public var path: String
    public var content: String
    public var sizeBytes: Int
    public var truncated: Bool

    public init(path: String, content: String, sizeBytes: Int, truncated: Bool) {
        self.path = path
        self.content = content
        self.sizeBytes = sizeBytes
        self.truncated = truncated
    }
}

public struct FileEntryWire: Encodable, Sendable, Equatable {
    public var name: String
    public var kind: String
    public var sizeBytes: Int?
    public var modifiedAt: String?

    public init(name: String, kind: String, sizeBytes: Int?, modifiedAt: String?) {
        self.name = name
        self.kind = kind
        self.sizeBytes = sizeBytes
        self.modifiedAt = modifiedAt
    }
}

public struct FileListWire: Encodable, Sendable, Equatable {
    public var path: String
    public var entries: [FileEntryWire]
    public var truncated: Bool

    public init(path: String, entries: [FileEntryWire], truncated: Bool) {
        self.path = path
        self.entries = entries
        self.truncated = truncated
    }
}

public struct FileWriteWire: Encodable, Sendable, Equatable {
    public var path: String
    public var bytesWritten: Int

    public init(path: String, bytesWritten: Int) {
        self.path = path
        self.bytesWritten = bytesWritten
    }
}
