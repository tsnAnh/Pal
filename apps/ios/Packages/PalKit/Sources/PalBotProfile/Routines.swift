import Foundation
import PalProtocol

public struct Routine: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let scheduleText: String?
    public let timeZoneID: String?
    public var isEnabled: Bool

    init?(_ wire: CronJobWire) {
        let title = (wire.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        id = wire.jobID
        self.title = title.isEmpty ? String(localized: "Untitled routine") : title
        scheduleText = wire.scheduleText
        timeZoneID = wire.scheduleTimezone
        isEnabled = wire.enabled ?? true
    }

    public init(id: String, title: String, scheduleText: String?, timeZoneID: String?, isEnabled: Bool) {
        self.id = id
        self.title = title
        self.scheduleText = scheduleText
        self.timeZoneID = timeZoneID
        self.isEnabled = isEnabled
    }

    public func caption(locale: Locale = .current) -> String {
        ScheduleCaption.text(scheduleText: scheduleText, timeZoneID: timeZoneID, locale: locale)
    }
}

public enum ScheduleCaption {
    public static func text(scheduleText: String?, timeZoneID: String?, locale: Locale = .current) -> String {
        let base = scheduleText?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? String(localized: "Custom schedule")
        guard let zone = zoneName(timeZoneID, locale: locale) else { return base }
        return "\(base) (\(zone))"
    }

    public static func zoneName(_ identifier: String?, locale: Locale = .current) -> String? {
        guard let identifier = identifier?.trimmingCharacters(in: .whitespacesAndNewlines), !identifier.isEmpty,
              let zone = TimeZone(identifier: identifier),
              let name = zone.localizedName(for: .generic, locale: locale), !name.isEmpty
        else { return nil }
        return stripTimeSuffix(name, locale: locale)
    }

    private static func stripTimeSuffix(_ name: String, locale: Locale) -> String {
        guard locale.language.languageCode?.identifier == "en", name.hasSuffix(" Time") else { return name }
        return String(name.dropLast(" Time".count))
    }
}

extension String {
    fileprivate var nonEmpty: String? { isEmpty ? nil : self }
}

public struct SchedulePreview: Sendable, Equatable {
    public let acceptedAs: String
    public let nextRun: Date?
}

public enum ScheduleRefusal: String, Sendable, Equatable {
    case empty
    case tooFrequent = "too_frequent"
    case unrecognized
    case invalid

    public var message: String {
        switch self {
        case .empty: String(localized: "Choose when this routine should run.")
        case .tooFrequent: String(localized: "Routines can run at most once every 5 minutes.")
        case .unrecognized, .invalid: String(localized: "That schedule was not understood.")
        }
    }
}

public enum RoutineError: Error, Sendable, Equatable {
    case scheduleRefused(ScheduleRefusal)
    case failed
}

public struct RoutineService: Sendable {
    public static let deliveryTarget = "bot-chat"

    private let gateway: BotsGateway

    public init(gateway: BotsGateway) {
        self.gateway = gateway
    }

    public func list(profile: String) async throws -> [Routine] {
        let result = try await manage(profile, ["action": "list", "include_disabled": true])
        return (result.jobs ?? []).compactMap(Routine.init)
    }

    public func setEnabled(_ enabled: Bool, routine id: String, profile: String) async throws {
        let result = try await manage(profile, ["action": .string(enabled ? "resume" : "pause"), "name": .string(id)])
        guard result.success != false, result.error == nil else { throw RoutineError.failed }
    }

    public func remove(routine id: String, profile: String) async throws {
        let result = try await manage(profile, ["action": "remove", "name": .string(id)])
        guard result.success != false, result.error == nil else { throw RoutineError.failed }
    }

    public func preview(schedule: String, profile: String) async throws -> SchedulePreview {
        let result = try await manage(profile, ["action": "schedule_preview", "schedule": .string(schedule)])
        guard result.success == true, let accepted = result.acceptedAs else {
            throw RoutineError.scheduleRefused(result.reason.flatMap(ScheduleRefusal.init(rawValue:)) ?? .invalid)
        }
        return SchedulePreview(acceptedAs: accepted, nextRun: result.nextRunAt.flatMap(LibraryTimestamp.parse))
    }

    @discardableResult
    public func add(title: String, prompt: String, schedule: String, profile: String) async throws -> Routine {
        let result = try await manage(profile, [
            "action": "add",
            "name": .string(title),
            "prompt": .string(prompt),
            "schedule": .string(schedule),
            "deliver": .string(Self.deliveryTarget),
        ])
        if result.success == false, let reason = result.reason.flatMap(ScheduleRefusal.init(rawValue:)) {
            throw RoutineError.scheduleRefused(reason)
        }
        guard result.success != false, result.error == nil, let routine = result.job.flatMap(Routine.init) else {
            throw RoutineError.failed
        }
        return routine
    }

    private func manage(_ profile: String, _ params: [String: JSONValue]) async throws -> CronManageWire {
        do {
            let result = try await gateway.scoped("cron.manage", profile: profile, params)
            return try gateway.decoded(CronManageWire.self, result)
        } catch {
            throw BotsError.surface(error)
        }
    }
}
