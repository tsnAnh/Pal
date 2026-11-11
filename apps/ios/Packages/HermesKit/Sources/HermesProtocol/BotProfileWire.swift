import Foundation

public struct ProfileRowWire: Codable, Sendable, Hashable {
    public var name: String
    public var displayName: String?
    public var isPrimary: Bool?
    public var routinesEnabled: Int?
    public var hasAvatar: Bool?
    public var uiMeta: JSONValue?
    public var uiMetaRevisions: [String: Int]?

    enum CodingKeys: String, CodingKey {
        case name
        case displayName = "display_name"
        case isPrimary = "is_primary"
        case routinesEnabled = "routines_enabled"
        case hasAvatar = "has_avatar"
        case uiMeta = "ui_meta"
        case uiMetaRevisions = "ui_meta_revisions"
    }
}

public struct ProfilesListWire: Codable, Sendable, Hashable {
    public var profiles: [ProfileRowWire]
}

public struct ProfilesRenameWire: Codable, Sendable, Hashable {
    public var ok: Bool
    public var name: String
    public var displayName: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case name
        case displayName = "display_name"
    }
}

public struct ProfileTemplateWire: Codable, Sendable, Hashable {
    public var filename: String
    public var data: String
    public var size: Int
    public var sha256: String
}

public struct ConfigValueWire: Codable, Sendable, Hashable {
    public var value: JSONValue?
}

public struct DisplayLeaseWire: Codable, Sendable, Hashable {
    public var holder: String
    public var viewerHash: String?
    public var ask: String?
    public var askAt: Double?

    enum CodingKeys: String, CodingKey {
        case holder
        case viewerHash = "viewer_hash"
        case ask
        case askAt = "ask_at"
    }
}

public struct DisplayLeaseResultWire: Codable, Sendable, Hashable {
    public var lease: DisplayLeaseWire
}

public struct DisplayObserveWire: Codable, Sendable, Hashable {
    public var ticket: String
    public var path: String
    public var viewerID: String
    public var lease: DisplayLeaseWire?

    enum CodingKeys: String, CodingKey {
        case ticket
        case path
        case viewerID = "viewer_id"
        case lease
    }
}

public struct DisplayStatusWire: Codable, Sendable, Hashable {
    public var supported: Bool
    public var installed: Bool
    public var running: Bool
    public var blocker: String?
    public var lease: DisplayLeaseWire?
}

public struct LibraryItemWire: Codable, Sendable, Hashable {
    public var id: String
    public var kind: String
    public var title: String
    public var subtitle: String
    public var url: String?
    public var assetRef: String?
    public var mime: String?
    public var size: Int?
    public var sessionID: String
    public var occurredAt: String

    enum CodingKeys: String, CodingKey {
        case id, kind, title, subtitle, url, mime, size
        case assetRef = "asset_ref"
        case sessionID = "session_id"
        case occurredAt = "occurred_at"
    }
}

public struct LibraryListWire: Codable, Sendable, Hashable {
    public var items: [LibraryItemWire]
    public var nextBefore: String?
    public var indexComplete: Bool

    enum CodingKeys: String, CodingKey {
        case items
        case nextBefore = "next_before"
        case indexComplete = "index_complete"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decode([LibraryItemWire].self, forKey: .items)
        nextBefore = try container.decodeIfPresent(String.self, forKey: .nextBefore)
        indexComplete = try container.decodeIfPresent(Bool.self, forKey: .indexComplete) ?? true
    }
}

public struct LibraryAssetWire: Codable, Sendable, Hashable {
    public var mime: String
    public var dataBase64: String
    public var size: Int

    enum CodingKeys: String, CodingKey {
        case mime
        case dataBase64 = "data_base64"
        case size
    }
}

public struct CronJobWire: Codable, Sendable, Hashable {
    public var jobID: String
    public var name: String?
    public var scheduleText: String?
    public var scheduleTimezone: String?
    public var enabled: Bool?
    public var nextRunAt: String?
    public var deliver: String?

    enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case name
        case scheduleText = "schedule_text"
        case scheduleTimezone = "schedule_timezone"
        case enabled
        case nextRunAt = "next_run_at"
        case deliver
    }
}

public struct CronManageWire: Codable, Sendable, Hashable {
    public var success: Bool?
    public var error: String?
    public var reason: String?
    public var jobs: [CronJobWire]?
    public var job: CronJobWire?
    public var schedule: String?
    public var acceptedAs: String?
    public var nextRunAt: String?

    enum CodingKeys: String, CodingKey {
        case success, error, reason, jobs, job, schedule
        case acceptedAs = "accepted_as"
        case nextRunAt = "next_run_at"
    }
}

public struct SlackStatusWire: Codable, Sendable, Hashable {
    public var enabled: Bool
    public var configured: Bool
    public var gatewayRunning: Bool
    public var state: String?
    public var errorCode: String?
    public var errorMessage: String?
    public var neededScope: String?
    public var providedScope: String?
    public var restartStarted: Bool?
    public var restartBusy: Bool?
    public var restartError: String?
    public var hotServed: Bool?

    enum CodingKeys: String, CodingKey {
        case enabled, configured, state
        case gatewayRunning = "gateway_running"
        case errorCode = "error_code"
        case errorMessage = "error_message"
        case neededScope = "needed_scope"
        case providedScope = "provided_scope"
        case restartStarted = "restart_started"
        case restartBusy = "restart_busy"
        case restartError = "restart_error"
        case hotServed = "hot_served"
    }
}

public struct SlackManifestWire: Codable, Sendable, Hashable {
    public var botName: String
    public var createURL: String

    enum CodingKeys: String, CodingKey {
        case botName = "bot_name"
        case createURL = "create_url"
    }
}

public struct CapabilityRowWire: Codable, Sendable, Hashable {
    public var id: String
    public var label: String?
    public var state: String?
    public var reason: String?
    public var keyName: String?
    public var keyChoices: [String]?
    public var setting: String?

    enum CodingKeys: String, CodingKey {
        case id, label, state, reason, setting
        case keyName = "key_name"
        case keyChoices = "key_choices"
    }
}

public struct CapabilitiesStatusWire: Codable, Sendable, Hashable {
    public var profile: String?
    public var capabilities: [CapabilityRowWire]

    enum CodingKeys: String, CodingKey {
        case profile, capabilities
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profile = try container.decodeIfPresent(String.self, forKey: .profile)
        var rows = try container.nestedUnkeyedContainer(forKey: .capabilities)
        var decoded: [CapabilityRowWire] = []
        while !rows.isAtEnd {
            if let row = try? rows.decode(CapabilityRowWire.self) {
                decoded.append(row)
            } else {
                _ = try? rows.decode(DiscardedValue.self)
            }
        }
        capabilities = decoded
    }

    private struct DiscardedValue: Decodable {
        init(from decoder: any Decoder) throws {}
    }
}
