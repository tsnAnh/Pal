import PalProtocol

public enum DeviceKind: String, Sendable, Hashable, CaseIterable {
    case ios
    case mac

    public static var current: DeviceKind {
        #if os(macOS)
        .mac
        #else
        .ios
        #endif
    }

    public var sectionName: String {
        switch self {
        case .ios: "iPhone"
        case .mac: "Mac"
        }
    }
}

public struct DeviceConnectorEntry: Sendable, Hashable, Identifiable {
    public let id: DeviceConnectorID
    public let title: String
    public let subtitle: String
    fileprivate let kinds: Set<DeviceKind>
}

public enum DeviceConnectorCatalog {
    public static func entries(for kind: DeviceKind) -> [DeviceConnectorEntry] {
        all.filter { $0.kinds.contains(kind) }
    }

    public static func rows(for kind: DeviceKind, reports: [DeviceConnectorID: DeviceConnectorReport]) -> [DeviceConnectorRow] {
        entries(for: kind).map { entry in
            DeviceConnectorRow(entry: entry, state: DeviceConnectorRowState(osPermission: reports[entry.id]?.osPermission))
        }
    }

    private static func entry(_ id: DeviceConnectorID, _ title: String, _ subtitle: String, _ kinds: Set<DeviceKind>) -> DeviceConnectorEntry {
        DeviceConnectorEntry(id: id, title: title, subtitle: subtitle, kinds: kinds)
    }

    private static let all: [DeviceConnectorEntry] = [
        entry(.calendar, "Calendar", "See your day and add events", [.ios, .mac]),
        entry(.home, "Home", "Control lights, locks and more", [.ios, .mac]),
        entry(.reminders, "Reminders", "Set and check reminders", [.ios, .mac]),
        entry(.contacts, "Contacts", "Look up people you know", [.ios, .mac]),
        entry(.location, "Location", "Find places near you", [.ios, .mac]),
        entry(.alarms, "Alarms and timers", "Set alarms and timers", [.ios, .mac]),
        entry(.notifications, "Notifications", "Show and remove notifications", [.mac]),
        entry(.input, "Mouse and keyboard", "Move the pointer, click and type", [.mac]),
        entry(.clipboard, "Clipboard", "Read and change the clipboard", [.mac]),
        entry(.screen, "Screen", "See what is on the screen", [.mac]),
        entry(.apps, "Apps and windows", "Open, switch and quit apps and windows", [.mac]),
        entry(.messages, "Messages", "Read and send your messages", [.mac]),
    ]
}

public struct DeviceConnectorRow: Sendable, Hashable, Identifiable {
    public let entry: DeviceConnectorEntry
    public let state: DeviceConnectorRowState

    public init(entry: DeviceConnectorEntry, state: DeviceConnectorRowState) {
        self.entry = entry
        self.state = state
    }

    public var id: DeviceConnectorID { entry.id }
}

public enum DeviceConnectorRowState: Sendable, Hashable {
    case allowed
    case allow
    case needsSystemPermission
    case unavailable
    case unknown

    public init(osPermission: DeviceOSPermission?) {
        switch osPermission {
        case .granted: self = .allowed
        case .notDetermined: self = .allow
        case .denied: self = .needsSystemPermission
        case .unsupported: self = .unavailable
        case nil: self = .unknown
        }
    }
}

public struct DeviceConnectorReport: Sendable, Hashable {
    public let id: DeviceConnectorID
    public let osPermission: DeviceOSPermission?

    public init(id: DeviceConnectorID, osPermission: DeviceOSPermission?) {
        self.id = id
        self.osPermission = osPermission
    }
}

public struct DeviceRowPresentation: Sendable, Hashable {
    public enum Action: Sendable, Hashable {
        case allow
        case openSettings
    }

    public let summary: String
    public let buttonTitle: String?
    public let action: Action?

    public init(row: DeviceConnectorRow) {
        let subtitle = row.entry.subtitle
        switch row.state {
        case .allowed: self.init(summary: subtitle, buttonTitle: "Allowed", action: nil)
        case .allow: self.init(summary: subtitle, buttonTitle: "Allow", action: .allow)
        case .needsSystemPermission: self.init(summary: "Needs a system permission", buttonTitle: "Open Settings", action: .openSettings)
        case .unavailable: self.init(summary: "Not available on this device", buttonTitle: nil, action: nil)
        case .unknown: self.init(summary: subtitle, buttonTitle: nil, action: nil)
        }
    }

    private init(summary: String, buttonTitle: String?, action: Action?) {
        self.summary = summary
        self.buttonTitle = buttonTitle
        self.action = action
    }
}
