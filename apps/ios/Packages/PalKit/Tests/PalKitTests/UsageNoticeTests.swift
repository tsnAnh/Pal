import Foundation
import PalProtocol
import PalSettings
import Testing

@Suite("Usage notice")
struct UsageNoticeTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static func overview(_ windows: [SettingsWire.UsageWindow], kind: String = "subscription") -> UsageOverview {
        UsageOverview([SettingsWire.Subscription(id: "a", provider: "p", providerLabel: "P", kind: kind, state: "ready", windows: windows)])
    }

    private static func window(_ label: String, _ percent: Double, days: Double = 5.2, scope: String? = nil) -> SettingsWire.UsageWindow {
        let reset = Date(timeIntervalSince1970: 1_800_000_000 + days * 86_400)
        return SettingsWire.UsageWindow(label: label, usedPercent: percent, resetsAt: reset.formatted(.iso8601), scope: scope)
    }

    @Test(arguments: [0.0, 42.0, 74.9])
    func belowTheFirstThresholdThereIsNoNotice(percent: Double) {
        #expect(UsageNotice(Self.overview([Self.window("Weekly", percent)])) == nil)
    }

    @Test(arguments: [(75.0, 75), (89.9, 75), (90.0, 90), (99.0, 90), (100.0, 100), (140.0, 100)])
    func stepFollowsTheHighestThresholdCrossed(percent: Double, step: Int) throws {
        let notice = try #require(UsageNotice(Self.overview([Self.window("Weekly", percent)])))
        #expect(notice.step == step)
        #expect(notice.percent <= 100)
    }

    @Test func theFullestAccountWideWindowDrivesTheCopy() throws {
        let notice = try #require(UsageNotice(Self.overview([
            Self.window("Session", 30), Self.window("Weekly", 75.6), Self.window("Premium requests", 99, scope: "model"),
        ])))
        #expect(notice.headline() == "You're at 75% of your weekly usage limit.")
        #expect(notice.resetLine(now: Self.now) == "It resets in 5 days.")
    }

    @Test func apiKeyAccountsNeverRaiseANotice() {
        #expect(UsageNotice(Self.overview([Self.window("Weekly", 95)], kind: "api_key")) == nil)
    }

    @Test func unnamedWindowsFallBackToAGenericLimit() throws {
        let notice = try #require(UsageNotice(Self.overview([SettingsWire.UsageWindow(label: "Chat", usedPercent: 80)])))
        #expect(notice.headline() == "You're at 80% of your usage limit.")
        #expect(notice.resetLine(now: Self.now) == nil)
    }

    @Test(arguments: [(30.0, "It resets soon."), (90.0, "It resets in 2 minutes."), (7_300.0, "It resets in 2 hours."), (86_400.0, "It resets in 1 day.")])
    func resetLineUsesTheCoarsestUnit(seconds: Double, expected: String) throws {
        let reset = Self.now.addingTimeInterval(seconds).formatted(.iso8601)
        let notice = try #require(UsageNotice(Self.overview([SettingsWire.UsageWindow(label: "Weekly", usedPercent: 80, resetsAt: reset)])))
        #expect(notice.resetLine(now: Self.now) == expected)
    }

    private func store() -> (UsageNoticeStore, UserDefaults) {
        let defaults = UserDefaults(suiteName: "usage-notice-\(UUID().uuidString)")!
        return (UsageNoticeStore(defaults: defaults, account: "acct"), defaults)
    }

    @Test func dismissalHoldsUntilTheNextStepOrTheNextCycle() throws {
        let (store, _) = store()
        let first = try #require(UsageNotice(Self.overview([Self.window("Weekly", 76)])))
        #expect(store.visible(first) == first)

        store.dismiss(first)
        #expect(store.visible(first) == nil)
        #expect(store.visible(try #require(UsageNotice(Self.overview([Self.window("Weekly", 88)])))) == nil)

        let nextStep = try #require(UsageNotice(Self.overview([Self.window("Weekly", 91)])))
        #expect(store.visible(nextStep) == nextStep)

        let nextCycle = try #require(UsageNotice(Self.overview([Self.window("Weekly", 76, days: 12.2)])))
        #expect(store.visible(nextCycle) == nextCycle)
    }

    @Test func dismissalSurvivesJitterInTheResetTimestamp() throws {
        let (store, _) = store()
        store.dismiss(try #require(UsageNotice(Self.overview([Self.window("Weekly", 80, days: 5.2)]))))
        let jittered = try #require(UsageNotice(Self.overview([Self.window("Weekly", 80, days: 5.2 + 30.0 / 86_400)])))
        #expect(store.visible(jittered) == nil)
    }

    @Test func dismissalIsPerAccountAndPersists() throws {
        let defaults = UserDefaults(suiteName: "usage-notice-\(UUID().uuidString)")!
        let notice = try #require(UsageNotice(Self.overview([Self.window("Weekly", 80)])))
        UsageNoticeStore(defaults: defaults, account: "one").dismiss(notice)
        #expect(UsageNoticeStore(defaults: defaults, account: "one").visible(notice) == nil)
        #expect(UsageNoticeStore(defaults: defaults, account: "two").visible(notice) == notice)
    }
}
