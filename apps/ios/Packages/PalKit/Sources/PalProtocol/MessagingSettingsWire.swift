import Foundation

public struct MessagingSettingsFieldWire: Codable, Sendable, Hashable {
    public var key: String
    public var kind: String
    public var label: String
    public var values: [String]
}

public struct MessagingSettingsSecretWire: Codable, Sendable, Hashable {
    public var key: String
    public var label: String
    public var isSet: Bool

    enum CodingKeys: String, CodingKey {
        case key, label
        case isSet = "is_set"
    }
}

public struct MessagingSettingsPlatformWire: Codable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var enabled: Bool
    public var configured: Bool
    public var state: String?
    public var errorMessage: String?
    public var fields: [MessagingSettingsFieldWire]
    public var secrets: [MessagingSettingsSecretWire]

    enum CodingKeys: String, CodingKey {
        case id, name, enabled, configured, state, fields, secrets
        case errorMessage = "error_message"
    }
}

public struct MessagingSettingsGetWire: Codable, Sendable, Hashable {
    public var profile: String
    public var gatewayRunning: Bool
    public var platforms: [MessagingSettingsPlatformWire]

    enum CodingKeys: String, CodingKey {
        case profile, platforms
        case gatewayRunning = "gateway_running"
    }
}

public struct MessagingSettingsUpdateWire: Codable, Sendable, Hashable {
    public var profile: String
    public var gatewayRunning: Bool
    public var settings: MessagingSettingsPlatformWire
    public var changed: Bool
    public var hotServed: Bool
    public var restartNeeded: Bool

    enum CodingKeys: String, CodingKey {
        case profile, settings, changed
        case gatewayRunning = "gateway_running"
        case hotServed = "hot_served"
        case restartNeeded = "restart_needed"
    }
}
