import Foundation

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

public struct ScreenCaptureArgs: Decodable, Sendable {
    public var display: Int?
    public var readText: Bool?
}

public struct ScreenReadArgs: Decodable, Sendable {
    public var display: Int?
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

public struct NotifyPostArgs: Decodable, Sendable {
    public var title: String
    public var body: String
    public var subtitle: String?
    public var sound: Bool?
    public var identifier: String?
}

public struct NotifyCancelArgs: Decodable, Sendable {
    public var identifier: String
}

public struct NotifyWire: Encodable, Sendable, Equatable {
    public var identifier: String

    public init(identifier: String) {
        self.identifier = identifier
    }
}

public struct AppsListArgs: Decodable, Sendable {
    public var limit: Int?
}

public struct AppsOpenArgs: Decodable, Sendable {
    public var app: String
    public var target: String?
}

public struct AppsQuitArgs: Decodable, Sendable {
    public var app: String
}

public struct WindowsListArgs: Decodable, Sendable {
    public var app: String?
    public var onScreenOnly: Bool?
    public var limit: Int?
}

public struct WindowsFocusArgs: Decodable, Sendable {
    public var windowId: Int?
    public var app: String?
}

public struct ClipboardReadArgs: Decodable, Sendable {
    public var includeImage: Bool?
}

public struct ClipboardWriteArgs: Decodable, Sendable {
    public var text: String?
    public var imageBase64: String?
}

public struct MessagesRecentArgs: Decodable, Sendable {
    public var limit: Int?
    public var messagesPerChat: Int?
}

public struct MessagesSearchArgs: Decodable, Sendable {
    public var query: String
    public var limit: Int?
}

public struct MessagesReadArgs: Decodable, Sendable {
    public var chatId: String
    public var limit: Int?
}

public struct MessagesSendArgs: Decodable, Sendable {
    public var recipient: String
    public var text: String
    public var service: String?
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
