import Foundation
import PalProtocol

public struct DeviceEntry: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let kindLabel: String
    public let symbolName: String
    public let isThisDevice: Bool
    public let isOnline: Bool
    public let lastSeen: Date?

    public init(_ device: SettingsWire.Device, localDeviceID: String? = nil) {
        id = device.deviceId
        name = device.label
        let kind = Self.kinds[device.kind] ?? (label: "Device", symbol: "questionmark.square.dashed")
        kindLabel = kind.label
        symbolName = kind.symbol
        isThisDevice = device.thisDevice || (localDeviceID.map { $0 == device.deviceId } ?? false)
        isOnline = device.online
        lastSeen = UsageClock.parse(device.lastSeenAt)
    }

    public func statusText(now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        if isThisDevice { return "This device" }
        if isOnline { return "Online now" }
        guard let lastSeen else { return "Not opened yet" }
        let sameYear = calendar.isDate(lastSeen, equalTo: now, toGranularity: .year)
        let style: Date.FormatStyle = sameYear
            ? .dateTime.month(.abbreviated).day().locale(locale)
            : .dateTime.month(.abbreviated).day().year().locale(locale)
        return "Last opened \(lastSeen.formatted(style))"
    }

    public func subtitle(now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        "\(kindLabel) · \(statusText(now: now, calendar: calendar, locale: locale))"
    }

    private static let kinds: [String: (label: String, symbol: String)] = [
        "ios": ("iOS", "iphone"),
        "mac": ("Mac", "laptopcomputer"),
        "desktop": ("Computer", "desktopcomputer"),
        "web": ("Browser", "globe"),
        "tui": ("Terminal", "terminal"),
        "cli": ("Terminal", "terminal"),
    ]

    public static func ordered(_ devices: [SettingsWire.Device], localDeviceID: String? = nil) -> [DeviceEntry] {
        devices.map { DeviceEntry($0, localDeviceID: localDeviceID) }.sorted { lhs, rhs in
            if lhs.isThisDevice != rhs.isThisDevice { return lhs.isThisDevice }
            if lhs.isOnline != rhs.isOnline { return lhs.isOnline }
            return (lhs.lastSeen ?? .distantPast) > (rhs.lastSeen ?? .distantPast)
        }
    }
}

public struct PermissionRuleEntry: Identifiable, Sendable, Equatable {
    public let id: String
    public let text: String

    public init(_ rule: SettingsWire.PermissionRule) {
        id = rule.id
        text = rule.text
    }
}

public struct PermissionsSummary: Sendable, Equatable {
    public let autoReview: Bool
    public let approvalsAreOff: Bool
    public let ask: [PermissionRuleEntry]
    public let allow: [PermissionRuleEntry]

    public init(_ state: SettingsWire.PermissionsState) {
        autoReview = state.autoReview
        approvalsAreOff = state.approvalMode == "off"
        ask = state.ask.map(PermissionRuleEntry.init)
        allow = state.allow.map(PermissionRuleEntry.init)
    }

    public var ruleCount: Int { ask.count + allow.count }

    public var rowSubtitle: String {
        "Auto-review \(autoReview ? "on" : "off") · \(UsageClock.count(ruleCount, "rule"))"
    }

    public func rules(in list: PermissionList) -> [PermissionRuleEntry] {
        list == .ask ? ask : allow
    }
}

public struct ComputerSummary: Sendable, Equatable {
    public enum Disk: Sendable, Equatable {
        case normal
        case low
        case critical
        case unknown

        init(_ disk: SettingsWire.DisplayDisk?) {
            switch disk?.level {
            case "normal": self = .normal
            case "low": self = .low
            case "critical": self = .critical
            default: self = .unknown
            }
        }

        public var text: String {
            switch self {
            case .normal: "Normal"
            case .low: "Low"
            case .critical: "Almost full"
            case .unknown: "Unavailable"
            }
        }
    }

    public let disk: Disk

    public init(_ status: SettingsWire.DisplayStatus) {
        disk = Disk(status.disk)
    }

    public init(_ reset: SettingsWire.DisplayReset) {
        disk = Disk(reset.disk)
    }
}
