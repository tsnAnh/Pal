import Foundation

public enum SettingsWire {
    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    public struct UsageWindow: Decodable, Sendable, Equatable {
        public var label: String
        public var usedPercent: Double
        public var resetsAt: String?
        public var scope: String?

        public init(label: String, usedPercent: Double, resetsAt: String? = nil, scope: String? = nil) {
            self.label = label
            self.usedPercent = usedPercent
            self.resetsAt = resetsAt
            self.scope = scope
        }
    }

    public struct Spend: Decodable, Sendable, Equatable {
        public var periodDays: Int
        public var usd: Double?
        public var inputTokens: Int
        public var outputTokens: Int

        public init(periodDays: Int, usd: Double? = nil, inputTokens: Int = 0, outputTokens: Int = 0) {
            self.periodDays = periodDays
            self.usd = usd
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
        }
    }

    public struct Subscription: Decodable, Sendable, Equatable {
        public var id: String
        public var provider: String
        public var providerLabel: String
        public var accountLabel: String?
        public var kind: String
        public var plan: String?
        public var active: Bool
        public var state: String
        public var windows: [UsageWindow]
        public var spend: Spend?
        public var unavailableReason: String?
        public var fetchedAt: String?

        public init(
            id: String, provider: String, providerLabel: String, accountLabel: String? = nil, kind: String,
            plan: String? = nil, active: Bool = false, state: String, windows: [UsageWindow] = [],
            spend: Spend? = nil, unavailableReason: String? = nil, fetchedAt: String? = nil
        ) {
            self.id = id
            self.provider = provider
            self.providerLabel = providerLabel
            self.accountLabel = accountLabel
            self.kind = kind
            self.plan = plan
            self.active = active
            self.state = state
            self.windows = windows
            self.spend = spend
            self.unavailableReason = unavailableReason
            self.fetchedAt = fetchedAt
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            provider = try container.decode(String.self, forKey: .provider)
            providerLabel = try container.decode(String.self, forKey: .providerLabel)
            accountLabel = try container.decodeIfPresent(String.self, forKey: .accountLabel)
            kind = try container.decode(String.self, forKey: .kind)
            plan = try container.decodeIfPresent(String.self, forKey: .plan)
            active = try container.decodeIfPresent(Bool.self, forKey: .active) ?? false
            state = try container.decode(String.self, forKey: .state)
            windows = try container.decodeIfPresent([UsageWindow].self, forKey: .windows) ?? []
            spend = try container.decodeIfPresent(Spend.self, forKey: .spend)
            unavailableReason = try container.decodeIfPresent(String.self, forKey: .unavailableReason)
            fetchedAt = try container.decodeIfPresent(String.self, forKey: .fetchedAt)
        }

        enum CodingKeys: String, CodingKey {
            case id, provider, providerLabel, accountLabel, kind, plan, active, state, windows, spend
            case unavailableReason, fetchedAt
        }
    }

    public struct SubscriptionsResult: Decodable, Sendable, Equatable {
        public var subscriptions: [Subscription]
    }

    public struct PermissionRule: Decodable, Sendable, Equatable {
        public var id: String
        public var text: String
        public var createdAt: String

        public init(id: String, text: String, createdAt: String = "") {
            self.id = id
            self.text = text
            self.createdAt = createdAt
        }
    }

    public struct PermissionsState: Decodable, Sendable, Equatable {
        public var autoReview: Bool
        public var approvalMode: String
        public var ask: [PermissionRule]
        public var allow: [PermissionRule]

        public init(autoReview: Bool, approvalMode: String, ask: [PermissionRule] = [], allow: [PermissionRule] = []) {
            self.autoReview = autoReview
            self.approvalMode = approvalMode
            self.ask = ask
            self.allow = allow
        }
    }

    public struct RuleRemoval: Decodable, Sendable, Equatable {
        public var removed: Bool
    }

    public struct VaultItem: Decodable, Sendable, Equatable {
        public var id: String
        public var kind: String
        public var label: String
        public var origin: String?
        public var identifier: String?
        public var identifierType: String?
        public var backend: String?
    }

    public struct VaultList: Decodable, Sendable, Equatable {
        public var items: [VaultItem]
    }

    public struct VaultAdded: Decodable, Sendable, Equatable {
        public var id: String
    }

    public struct VaultRemoval: Decodable, Sendable, Equatable {
        public var removed: Bool
    }

    public struct DisplayDisk: Decodable, Sendable, Equatable {
        public var level: String
        public var freeMb: Int
        public var totalMb: Int
        public var usedPct: Int
    }

    public struct DisplayStatus: Decodable, Sendable, Equatable {
        public var supported: Bool
        public var installed: Bool
        public var running: Bool
        public var disk: DisplayDisk?
    }

    public struct DisplayReset: Decodable, Sendable, Equatable {
        public var supported: Bool
        public var running: Bool
        public var disk: DisplayDisk?
        public var reset: [String]
    }

    public struct Device: Decodable, Sendable, Equatable {
        public var deviceId: String
        public var kind: String
        public var label: String
        public var model: String?
        public var os: String?
        public var thisDevice: Bool
        public var online: Bool
        public var lastSeenAt: String
        public var pushEnabled: Bool
    }

    public struct DevicesList: Decodable, Sendable, Equatable {
        public var devices: [Device]
    }

    public struct DeviceForgotten: Decodable, Sendable, Equatable {
        public var forgotten: Bool
        public var grantsRevoked: Int
        public var pushRemoved: Bool
    }

    public struct AboutYou: Decodable, Sendable, Equatable {
        public var name: String
        public var timezone: String
        public var timezoneAuto: Bool

        public init(name: String = "", timezone: String = "", timezoneAuto: Bool = false) {
            self.name = name
            self.timezone = timezone
            self.timezoneAuto = timezoneAuto
        }
    }

    public struct SharedMetrics: Decodable, Sendable, Equatable {
        public var enabled: Bool
        public var send: Bool
        public var decided: Bool
    }

    public struct MemoryImport: Decodable, Sendable, Equatable {
        public var candidates: Int
        public var added: Int
        public var duplicates: Int
        public var tooLong: Int
        public var blocked: Int
        public var overBudget: Int
    }

    public struct ConfigValue: Decodable, Sendable, Equatable {
        public var key: String?
        public var value: JSONValue?
    }
}
