import Foundation
import PalProtocol

public struct UsageMeter: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let usedPercent: Double
    public let resetsAt: Date?
    public let isModelScoped: Bool

    public init(window: SettingsWire.UsageWindow, accountID: String) {
        id = "\(accountID)/\(window.label)"
        title = Self.title(for: window.label)
        usedPercent = window.usedPercent.isFinite ? min(100, max(0, window.usedPercent)) : 0
        resetsAt = window.resetsAt.flatMap(UsageClock.parse)
        isModelScoped = window.scope == "model"
    }

    public var fraction: Double { usedPercent / 100 }

    public var percentText: String {
        if usedPercent > 0, usedPercent < 0.5 { return "<1%" }
        return "\(Int(usedPercent.rounded()))%"
    }

    public var isExhausted: Bool { usedPercent >= 100 }

    public func resetText(now: Date) -> String? {
        resetsAt.map { UsageClock.resetText(until: $0, now: now) }
    }

    private static let limitWindows: Set<String> = ["Session", "Weekly", "Daily", "Monthly", "Hourly"]

    private static func title(for label: String) -> String {
        limitWindows.contains(label) ? "\(label) usage limit" : label
    }
}

public enum UsageClock {
    public static func parse(_ text: String) -> Date? {
        (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text))
            ?? (try? Date.ISO8601FormatStyle().parse(text))
    }

    public static func resetText(until date: Date, now: Date) -> String {
        let seconds = date.timeIntervalSince(now)
        guard seconds >= 60 else { return "Resets soon" }
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 60 { return "Resets in \(count(minutes, "minute"))" }
        let hours = Int(seconds / 3600)
        if hours < 24 { return "Resets in \(count(hours, "hour"))" }
        return "Resets in \(count(hours / 24, "day"))"
    }

    public static func count(_ value: Int, _ unit: String) -> String {
        "\(value) \(unit)\(value == 1 ? "" : "s")"
    }
}

public struct UsageSpend: Sendable, Equatable {
    public let periodDays: Int
    public let usd: Double?
    public let tokens: Int

    public init(_ spend: SettingsWire.Spend) {
        periodDays = spend.periodDays
        usd = spend.usd
        tokens = spend.inputTokens + spend.outputTokens
    }

    public var title: String { "Spend, last \(UsageClock.count(periodDays, "day"))" }

    public func valueText(locale: Locale = .current) -> String {
        if let usd {
            let price = FloatingPointFormatStyle<Double>.Currency(code: "USD", locale: locale)
            return usd > 0 && usd < 0.01 ? "<\(0.01.formatted(price))" : usd.formatted(price)
        }
        return tokens == 0 ? "No usage" : "\(Self.compact(tokens)) tokens"
    }

    public var hasActivity: Bool { tokens > 0 || (usd ?? 0) > 0 }

    public var detailText: String? {
        guard usd != nil, tokens > 0 else { return nil }
        return "\(Self.compact(tokens)) tokens"
    }

    private static func compact(_ tokens: Int) -> String {
        tokens.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }
}

public struct UsageAccount: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case subscription
        case apiKey = "api_key"
    }

    public enum Standing: Sendable, Equatable {
        case ready
        case limited
        case unknown
        case unavailable
    }

    public let id: String
    public let providerTitle: String
    public let accountLabel: String?
    public let plan: String?
    public let kind: Kind
    public let standing: Standing
    public let isActive: Bool
    public let meters: [UsageMeter]
    public let spend: UsageSpend?
    public let note: String?

    public init(_ subscription: SettingsWire.Subscription) {
        id = subscription.id
        providerTitle = subscription.providerLabel
        accountLabel = subscription.accountLabel
        plan = subscription.plan
        kind = Kind(rawValue: subscription.kind) ?? .apiKey
        standing = switch subscription.state {
        case "ready": .ready
        case "limited": .limited
        case "unavailable": .unavailable
        default: .unknown
        }
        isActive = subscription.active
        meters = subscription.windows.map { UsageMeter(window: $0, accountID: subscription.id) }
        spend = subscription.spend.map(UsageSpend.init).flatMap { $0.hasActivity ? $0 : nil }
        note = Self.note(for: subscription, kind: kind)
    }

    public var title: String {
        guard let plan, !plan.isEmpty else { return providerTitle }
        return "\(providerTitle) \(plan)"
    }

    public var hasNoLimits: Bool { meters.isEmpty && kind == .apiKey && standing != .unavailable }

    public var headline: Double? {
        meters.filter { !$0.isModelScoped }.map(\.usedPercent).max()
    }

    private static func note(for subscription: SettingsWire.Subscription, kind: Kind) -> String? {
        guard subscription.windows.isEmpty else { return nil }
        if kind == .apiKey, subscription.state == "unknown" { return nil }
        return subscription.unavailableReason
    }
}

public struct UsageOverview: Sendable, Equatable {
    public let accounts: [UsageAccount]

    public init(_ subscriptions: [SettingsWire.Subscription]) {
        accounts = subscriptions.map(UsageAccount.init)
    }

    public var headlinePercent: Double? {
        accounts.filter { $0.kind == .subscription }.compactMap(\.headline).max()
    }

    public var headlineText: String? {
        headlinePercent.map { UsageMeter.percentText(for: $0) }
    }
}

extension UsageMeter {
    public static func percentText(for percent: Double) -> String {
        UsageMeter(window: SettingsWire.UsageWindow(label: "", usedPercent: percent), accountID: "").percentText
    }
}
