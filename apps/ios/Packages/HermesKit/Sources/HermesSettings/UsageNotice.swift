import Foundation

public struct UsageNotice: Sendable, Equatable {
    public static let thresholds = [75, 90, 100]

    public let meterID: String
    public let windowName: String?
    public let percent: Int
    public let step: Int
    public let resetsAt: Date?

    public init?(_ overview: UsageOverview) {
        let candidates = overview.accounts
            .filter { $0.kind == .subscription }
            .flatMap(\.meters)
            .filter { !$0.isModelScoped }
        guard let worst = candidates.max(by: { $0.usedPercent < $1.usedPercent }),
              let step = Self.thresholds.last(where: { worst.usedPercent >= Double($0) })
        else { return nil }
        meterID = worst.id
        windowName = Self.windowName(of: worst.title)
        percent = min(100, Int(worst.usedPercent.rounded(.down)))
        self.step = step
        resetsAt = worst.resetsAt
    }

    public func headline() -> String {
        if let windowName { return "You're at \(percent)% of your \(windowName) usage limit." }
        return "You're at \(percent)% of your usage limit."
    }

    public func resetLine(now: Date) -> String? {
        guard let resetsAt else { return nil }
        let seconds = resetsAt.timeIntervalSince(now)
        guard seconds >= 60 else { return "It resets soon." }
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 60 { return "It resets in \(UsageClock.count(minutes, "minute"))." }
        let hours = Int(seconds / 3600)
        if hours < 24 { return "It resets in \(UsageClock.count(hours, "hour"))." }
        return "It resets in \(UsageClock.count(hours / 24, "day"))."
    }

    private static func windowName(of title: String) -> String? {
        let suffix = " usage limit"
        guard title.hasSuffix(suffix) else { return nil }
        return String(title.dropLast(suffix.count)).lowercased()
    }
}

public struct UsageNoticeDismissal: Sendable, Equatable, Codable {
    public static let sameCycleSlack: TimeInterval = 3600

    public let meterID: String
    public let step: Int
    public let resetsAt: Date?

    public init(_ notice: UsageNotice) {
        meterID = notice.meterID
        step = notice.step
        resetsAt = notice.resetsAt
    }

    public func suppresses(_ notice: UsageNotice) -> Bool {
        guard notice.meterID == meterID, notice.step <= step else { return false }
        switch (resetsAt, notice.resetsAt) {
        case let (dismissed?, current?): return current.timeIntervalSince(dismissed) <= Self.sameCycleSlack
        default: return true
        }
    }
}

public struct UsageNoticeStore {
    public static let keyPrefix = "hermes.usage.notice.dismissed."

    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, account: String) {
        self.defaults = defaults
        key = Self.keyPrefix + account
    }

    public var dismissal: UsageNoticeDismissal? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(UsageNoticeDismissal.self, from: $0) }
    }

    public func dismiss(_ notice: UsageNotice) {
        guard let data = try? JSONEncoder().encode(UsageNoticeDismissal(notice)) else { return }
        defaults.set(data, forKey: key)
    }

    public func visible(_ notice: UsageNotice?) -> UsageNotice? {
        guard let notice else { return nil }
        return dismissal?.suppresses(notice) == true ? nil : notice
    }
}
