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
    case apps
    case notifications
    case clipboard
    case screen
    case input
    case messages

    public var needsOSPermission: Bool {
        switch self {
        case .shell, .files, .apps: false
        case .calendar, .home, .reminders, .contacts, .location, .alarms, .notifications, .clipboard, .screen, .input, .messages: true
        }
    }

    public var asksOSPermissionOnUse: Bool { self != .screen && self != .notifications && self != .input && self != .messages }
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
    case screenCapture = "screen.capture"
    case screenRead = "screen.read"
    case inputDisplays = "input.displays"
    case inputMove = "input.move"
    case inputClick = "input.click"
    case inputDrag = "input.drag"
    case inputScroll = "input.scroll"
    case inputType = "input.type"
    case inputKey = "input.key"
    case notifyPost = "notify.post"
    case notifyCancel = "notify.cancel"
    case appsList = "apps.list"
    case appsOpen = "apps.open"
    case appsQuit = "apps.quit"
    case windowsList = "windows.list"
    case windowsFocus = "windows.focus"
    case clipboardRead = "clipboard.read"
    case clipboardWrite = "clipboard.write"
    case messagesRecent = "messages.recent"
    case messagesSearch = "messages.search"
    case messagesRead = "messages.read"
    case messagesSend = "messages.send"

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
        case .screenCapture, .screenRead: .screen
        case .inputDisplays, .inputMove, .inputClick, .inputDrag, .inputScroll, .inputType, .inputKey: .input
        case .notifyPost, .notifyCancel: .notifications
        case .appsList, .appsOpen, .appsQuit, .windowsList, .windowsFocus: .apps
        case .clipboardRead, .clipboardWrite: .clipboard
        case .messagesRecent, .messagesSearch, .messagesRead, .messagesSend: .messages
        }
    }
}

public enum DeviceToolErrorCode: String, Codable, Sendable, Hashable {
    case permissionDenied = "permission_denied"
    case permissionNeeded = "permission_needed"
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
