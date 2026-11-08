import Foundation
import HermesProtocol
import HermesSettings
import HermesTransport
import Synchronization
import Testing

@Suite("Settings usage mapping")
struct UsageMappingTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static func decode(_ json: String) throws -> [SettingsWire.Subscription] {
        try SettingsWire.decoder.decode(SettingsWire.SubscriptionsResult.self, from: Data(json.utf8)).subscriptions
    }

    private static let liveShapes = """
    {"subscriptions": [
      {"id": "codex-1", "provider": "openai-codex", "provider_label": "ChatGPT", "account_label": "me@example.com",
       "kind": "subscription", "plan": "Plus", "active": true, "state": "ready",
       "windows": [
         {"label": "Session", "used_percent": 12.4, "resets_at": "2027-01-15T11:30:00+00:00", "scope": "account"},
         {"label": "Weekly", "used_percent": 42.0, "resets_at": "2027-01-21T08:00:00Z", "scope": "account"}],
       "spend": {"period_days": 7, "usd": null, "input_tokens": 1200, "output_tokens": 300},
       "fetched_at": "2027-01-15T08:00:00Z"},
      {"id": "copilot", "provider": "copilot", "provider_label": "GitHub Copilot", "kind": "subscription",
       "plan": "Free", "active": false, "state": "ready",
       "windows": [
         {"label": "Premium requests", "used_percent": 80, "resets_at": null, "scope": "model"},
         {"label": "Chat", "used_percent": 10, "scope": "account"},
         {"label": "Completions", "used_percent": 55.5}]},
      {"id": "openai", "provider": "openai", "provider_label": "OpenAI", "kind": "api_key", "active": false,
       "state": "unknown", "windows": [], "unavailable_reason": "This provider does not report usage limits.",
       "spend": {"period_days": 7, "usd": 3.456, "input_tokens": 120000, "output_tokens": 45000}},
      {"id": "dead", "provider": "anthropic", "provider_label": "Anthropic", "kind": "subscription",
       "state": "unavailable", "unavailable_reason": "This credential was rejected and needs to be signed in again."}
    ]}
    """

    @Test func decodesEverySubscriptionShapeTheContractAllows() throws {
        let overview = UsageOverview(try Self.decode(Self.liveShapes))
        #expect(overview.accounts.map(\.title) == ["ChatGPT Plus", "GitHub Copilot Free", "OpenAI", "Anthropic"])
        #expect(overview.accounts.map(\.kind) == [.subscription, .subscription, .apiKey, .subscription])
        #expect(overview.accounts.map(\.standing) == [.ready, .ready, .unknown, .unavailable])
        #expect(overview.accounts[0].isActive)
        #expect(overview.accounts[0].accountLabel == "me@example.com")
    }

    @Test func windowsMapToTitlesPercentsAndScopes() throws {
        let accounts = UsageOverview(try Self.decode(Self.liveShapes)).accounts
        #expect(accounts[0].meters.map(\.title) == ["Session usage limit", "Weekly usage limit"])
        #expect(accounts[0].meters.map(\.percentText) == ["12%", "42%"])
        #expect(accounts[1].meters.map(\.title) == ["Premium requests", "Chat", "Completions"])
        #expect(accounts[1].meters.map(\.isModelScoped) == [true, false, false])
        #expect(accounts[1].meters.map(\.percentText) == ["80%", "10%", "56%"])
        #expect(accounts[1].meters[0].resetsAt == nil)
    }

    @Test func overviewHeadlineIsTheBusiestAccountWideWindowOfASubscription() throws {
        let overview = UsageOverview(try Self.decode(Self.liveShapes))
        #expect(overview.headlinePercent == 55.5)
        #expect(overview.headlineText == "56%")
        #expect(UsageOverview([]).headlineText == nil)
    }

    @Test func apiKeyProvidersReadAsNoLimitsWithSpend() throws {
        let account = UsageOverview(try Self.decode(Self.liveShapes)).accounts[2]
        #expect(account.hasNoLimits)
        #expect(account.note == nil)
        #expect(account.spend?.title == "Spend, last 7 days")
        #expect(account.spend?.valueText(locale: Locale(identifier: "en_US")) == "$3.46")
        #expect(account.spend?.detailText == "165K tokens")
    }

    @Test func spendWithoutPricesFallsBackToTokensAndTinyAmountsRound() {
        #expect(UsageSpend(.init(periodDays: 1, usd: nil, inputTokens: 900, outputTokens: 100)).valueText(locale: Locale(identifier: "en_US")) == "1K tokens")
        #expect(!UsageSpend(.init(periodDays: 1, usd: nil, inputTokens: 0, outputTokens: 0)).hasActivity)
        #expect(UsageSpend(.init(periodDays: 1, usd: 0.004, inputTokens: 10, outputTokens: 0)).valueText(locale: Locale(identifier: "en_US")) == "<$0.01")
        #expect(!UsageSpend(.init(periodDays: 1, usd: 0, inputTokens: 0, outputTokens: 0)).hasActivity)
    }

    @Test func unavailableCredentialsKeepTheirReasonAndAreNeverNoLimits() throws {
        let account = UsageOverview(try Self.decode(Self.liveShapes)).accounts[3]
        #expect(account.note == "This credential was rejected and needs to be signed in again.")
        #expect(!account.hasNoLimits)
        #expect(account.meters.isEmpty)
    }

    @Test(arguments: [
        (0.0, "0%"), (0.2, "<1%"), (0.5, "1%"), (41.6, "42%"), (99.5, "100%"),
        (100.0, "100%"), (140.0, "100%"), (-5.0, "0%"), (Double.nan, "0%"),
    ])
    func percentTextClampsAndRounds(percent: Double, expected: String) {
        let meter = UsageMeter(window: .init(label: "Weekly", usedPercent: percent), accountID: "a")
        #expect(meter.percentText == expected)
        #expect((0...1).contains(meter.fraction))
    }

    @Test(arguments: [
        (-30.0, "Resets soon"), (0.0, "Resets soon"), (59.0, "Resets soon"), (60.0, "Resets in 1 minute"),
        (61.0, "Resets in 2 minutes"), (3_540.0, "Resets in 59 minutes"), (3_600.0, "Resets in 1 hour"),
        (7_300.0, "Resets in 2 hours"), (86_399.0, "Resets in 23 hours"), (86_400.0, "Resets in 1 day"),
        (6.4 * 86_400, "Resets in 6 days"),
    ])
    func resetTextFormatsTheRemainingTime(seconds: Double, expected: String) {
        let resetsAt = Self.now.addingTimeInterval(seconds)
        #expect(UsageClock.resetText(until: resetsAt, now: Self.now) == expected)
    }

    @Test func resetTimestampsParseWithAndWithoutFractionsAndOffsets() {
        let expected = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(UsageClock.parse("2027-01-15T08:00:00Z") == UsageClock.parse("2027-01-15T15:00:00.000+07:00"))
        #expect(UsageClock.parse("2027-01-15T08:00:00Z") != nil)
        #expect(UsageClock.parse("not a date") == nil)
        _ = expected
    }

    @Test func meterResetTextIsNilWithoutAResetTime() throws {
        let meters = UsageOverview(try Self.decode(Self.liveShapes)).accounts[1].meters
        #expect(meters[0].resetText(now: Self.now) == nil)
    }

    @Test func minimalWireRowsDecodeWithDefaults() throws {
        let rows = try Self.decode(#"{"subscriptions":[{"id":"x","provider":"p","provider_label":"P","kind":"api_key","state":"ready"}]}"#)
        #expect(rows[0].windows.isEmpty)
        #expect(rows[0].active == false)
        #expect(rows[0].spend == nil)
    }
}

@Suite("Settings devices, permissions and computer mapping")
struct DeviceAndPermissionMappingTests {
    private static let now = ISO8601DateFormatter().date(from: "2026-11-08T10:00:00Z")!
    private static let locale = Locale(identifier: "en_US")
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private static func devices(_ json: String) throws -> [SettingsWire.Device] {
        try SettingsWire.decoder.decode(SettingsWire.DevicesList.self, from: Data(json.utf8)).devices
    }

    private static let list = """
    {"devices": [
      {"device_id": "AAAAAAAA-1", "kind": "desktop", "label": "tsnanh", "this_device": false, "online": false,
       "last_seen_at": "2026-09-13T04:00:00Z", "push_enabled": false},
      {"device_id": "BBBBBBBB-2", "kind": "desktop", "label": "Bens-MacBook-Pro.local", "this_device": false,
       "online": true, "last_seen_at": "2026-11-08T09:59:00Z", "push_enabled": false, "os": "macOS"},
      {"device_id": "CCCCCCCC-3", "kind": "ios", "label": "iPhone", "model": "iPhone17,1", "this_device": true,
       "online": true, "last_seen_at": "2026-11-08T10:00:00Z", "push_enabled": true},
      {"device_id": "DDDDDDDD-4", "kind": "web", "label": "Safari", "this_device": false, "online": false,
       "last_seen_at": "2025-12-24T10:00:00Z", "push_enabled": false}
    ]}
    """

    @Test func thisDeviceComesFirstThenOnlineThenNewest() throws {
        let entries = DeviceEntry.ordered(try Self.devices(Self.list))
        #expect(entries.map(\.name) == ["iPhone", "Bens-MacBook-Pro.local", "tsnanh", "Safari"])
        #expect(entries.map(\.isThisDevice) == [true, false, false, false])
    }

    @Test func subtitlesMatchTheReferenceWording() throws {
        let entries = DeviceEntry.ordered(try Self.devices(Self.list))
        let subtitles = entries.map { $0.subtitle(now: Self.now, calendar: Self.utc, locale: Self.locale) }
        #expect(subtitles == [
            "iOS · This device", "Computer · Online now", "Computer · Last opened Sep 13",
            "Browser · Last opened Dec 24, 2025",
        ])
    }

    @Test func thisDeviceIsDetectedFromTheServerFlagOrTheLocalIdentity() throws {
        let wire = try Self.devices(Self.list)
        #expect(DeviceEntry(wire[2]).isThisDevice)
        #expect(!DeviceEntry(wire[1]).isThisDevice)
        #expect(DeviceEntry(wire[1], localDeviceID: "BBBBBBBB-2").isThisDevice)
        #expect(!DeviceEntry(wire[1], localDeviceID: "something-else").isThisDevice)
    }

    @Test func symbolsFollowTheDeviceKind() throws {
        let entries = DeviceEntry.ordered(try Self.devices(Self.list))
        #expect(entries.map(\.symbolName) == ["iphone", "desktopcomputer", "desktopcomputer", "globe"])
    }

    @Test func unknownKindsStillRender() throws {
        let wire = try Self.devices("""
        {"devices": [{"device_id": "EEEEEEEE-5", "kind": "toaster", "label": "Kitchen", "this_device": false,
          "online": false, "last_seen_at": "garbage", "push_enabled": false}]}
        """)
        let entry = DeviceEntry(wire[0])
        #expect(entry.kindLabel == "Device")
        #expect(entry.statusText(now: Self.now) == "Not opened yet")
    }

    @Test func permissionsSummaryCountsBothListsAndPluralises() throws {
        func summary(_ json: String) throws -> PermissionsSummary {
            PermissionsSummary(try SettingsWire.decoder.decode(SettingsWire.PermissionsState.self, from: Data(json.utf8)))
        }
        let empty = try summary(#"{"auto_review":true,"approval_mode":"smart","ask":[],"allow":[]}"#)
        #expect(empty.rowSubtitle == "Auto-review on · 0 rules")
        let one = try summary(#"{"auto_review":false,"approval_mode":"manual","ask":[{"id":"1","text":"a","created_at":"x"}],"allow":[]}"#)
        #expect(one.rowSubtitle == "Auto-review off · 1 rule")
        let two = try summary("""
        {"auto_review":true,"approval_mode":"smart","ask":[{"id":"1","text":"a","created_at":"x"}],
         "allow":[{"id":"2","text":"b","created_at":"x"}]}
        """)
        #expect(two.rowSubtitle == "Auto-review on · 2 rules")
        #expect(two.rules(in: .allow).map(\.text) == ["b"])
        #expect(!two.approvalsAreOff)
        #expect(try summary(#"{"auto_review":false,"approval_mode":"off","ask":[],"allow":[]}"#).approvalsAreOff)
    }

    @Test func computerDiskLevelsReadInProductWords() throws {
        func summary(_ level: String?) throws -> ComputerSummary {
            let disk = level.map { #""disk":{"level":"\#($0)","free_mb":10,"total_mb":100,"used_pct":90},"# } ?? ""
            let json = #"{\#(disk)"supported":false,"installed":false,"running":false}"#
            return ComputerSummary(try SettingsWire.decoder.decode(SettingsWire.DisplayStatus.self, from: Data(json.utf8)))
        }
        #expect(try summary("normal").disk.text == "Normal")
        #expect(try summary("low").disk.text == "Low")
        #expect(try summary("critical").disk.text == "Almost full")
        #expect(try summary(nil).disk.text == "Unavailable")
    }
}

@Suite("Settings vault drafts, failures and wire params")
struct SettingsBehaviourTests {
    @Test func loginDraftNeedsEveryFieldAndANormalisableWebsite() {
        var draft = VaultLoginDraft(label: "Shop", website: "shop.example.com", identifier: "me@example.com", password: "pw")
        #expect(draft.isComplete)
        #expect(draft.normalizedOrigin == "https://shop.example.com")
        #expect(draft.identifierType == "email")
        draft.password = ""
        #expect(!draft.isComplete)
        draft.password = "pw"
        draft.website = "ftp://shop.example.com"
        #expect(draft.normalizedOrigin == nil)
        draft.website = "   "
        #expect(!draft.isComplete)
        #expect(VaultLoginDraft(identifier: "+84 912 345 678").identifierType == "phone")
        #expect(VaultLoginDraft(identifier: "tsnanh").identifierType == "username")
    }

    @Test func vaultEntriesExposeNamesAndKindsNeverSecrets() throws {
        let list = try SettingsWire.decoder.decode(SettingsWire.VaultList.self, from: Data("""
        {"items": [
          {"id": "1", "kind": "login", "label": "Shop", "origin": "https://shop.example.com", "identifier": "me@example.com",
           "identifier_type": "email", "backend": "local", "has_otp": true},
          {"id": "2", "kind": "payment", "label": "Visa", "backend": "bitwarden"},
          {"id": "3", "kind": "mystery", "label": "?"}]}
        """.utf8))
        let entries = list.items.map(VaultEntry.init)
        #expect(entries.map(\.kind) == [.login, .payment, .other])
        #expect(entries[0].subtitle == "me@example.com · shop.example.com")
        #expect(entries[1].subtitle == nil)
        #expect(entries.map(\.isRemovable) == [true, false, true])
    }

    @Test func failuresClassifyByReasonAndSpeakProductLanguage() {
        func failure(_ data: JSONValue?, code: Int = 4001) -> SettingsFailure {
            SettingsFailure(GatewayTransportError.rpc(RPCError(code: code, message: "raw message", data: data)))
        }
        #expect(failure(["reason": "permission_denied"]) == .notAllowed)
        #expect(failure(["reason": "profile_mismatch"]) == .notAllowed)
        #expect(failure(["reason": "storage_unavailable"]) == .unavailable)
        #expect(failure(["reason": "not_found"]) == .notFound)
        #expect(failure(["code": "duplicate_rule"], code: 5320) == .rejected(code: "duplicate_rule"))
        #expect(failure(nil) == .unexpected)
        #expect(SettingsFailure(GatewayTransportError.timedOut) == .offline)
        #expect(SettingsFailure(URLError(.notConnectedToInternet)) == .offline)
        #expect(SettingsFailure.rejected(code: "duplicate_rule").message == "That rule already exists.")
        #expect(SettingsFailure.rejected(code: "zzz").message == "Hermes could not complete that.")
        for sample in [SettingsFailure.notAllowed, .unavailable, .notFound, .offline, .unexpected] {
            #expect(!sample.message.contains("RPC") && !sample.message.contains("_"))
        }
    }

    @Test func memoryImportSummaryNamesWhatLandedAndWhatWasSkipped() throws {
        func summary(_ added: Int, duplicates: Int = 0, tooLong: Int = 0, blocked: Int = 0, overBudget: Int = 0) throws -> MemoryImportSummary {
            let json = "{\"candidates\":\(added + duplicates + tooLong + blocked + overBudget),\"added\":\(added),\"duplicates\":\(duplicates),\"too_long\":\(tooLong),\"blocked\":\(blocked),\"over_budget\":\(overBudget)}"
            return MemoryImportSummary(try SettingsWire.decoder.decode(SettingsWire.MemoryImport.self, from: Data(json.utf8)))
        }
        #expect(try summary(1).text == "Added 1 memory.")
        #expect(try summary(2, duplicates: 1).text == "Added 2 memories. 1 already remembered.")
        #expect(try summary(0, tooLong: 2, blocked: 1, overBudget: 3).text == "Added 0 memories. 2 too long. 1 not allowed. 3 did not fit in memory.")
        #expect(try summary(0).text == "Nothing to import.")
        #expect(try summary(4).added == 4)
    }

    @Test func notificationFlagReadsEveryShapeTheConfigReaderReturns() {
        #expect(NotificationFlag.isOn(.string("on")))
        #expect(!NotificationFlag.isOn(.string("off")))
        #expect(!NotificationFlag.isOn(.bool(false)))
        #expect(NotificationFlag.isOn(.bool(true)))
        #expect(NotificationFlag.isOn(nil))
    }
}

@Suite("Settings API wire calls")
struct SettingsAPICallTests {
    private final class Recorder: Sendable {
        private let store = Mutex<[(String, JSONValue?)]>([])
        var calls: [(String, JSONValue?)] { store.withLock { $0 } }
        func record(_ method: String, _ params: JSONValue?) { store.withLock { $0.append((method, params)) } }
    }

    private static func api(profile: String? = "default", reply: JSONValue, recorder: Recorder) -> SettingsAPI {
        SettingsAPI(profile: profile) { method, params in
            recorder.record(method, params)
            return reply
        }
    }

    @Test func profileScopedVerbsCarryTheProfileAndDeviceVerbsDoNot() async throws {
        let recorder = Recorder()
        let reply: JSONValue = ["devices": [], "forgotten": true, "grants_revoked": 1, "push_removed": false]
        let api = Self.api(reply: reply, recorder: recorder)
        _ = try await api.devices()
        try await api.forgetDevice(id: "BBBBBBBB-2")
        let calls = recorder.calls
        #expect(calls[0].0 == "devices.list")
        #expect(calls[0].1?["profile"] == nil)
        #expect(calls[1].0 == "devices.forget")
        #expect(calls[1].1?["device_id"] == "BBBBBBBB-2")
        #expect(calls[1].1?["profile"] == nil)
    }

    @Test func timezoneAndNotificationWritesUseTheCanonicalVerbs() async throws {
        let recorder = Recorder()
        let reply: JSONValue = ["name": "", "timezone": "Asia/Ho_Chi_Minh", "timezone_auto": true, "key": "bot_mode.notifications", "value": "off"]
        let api = Self.api(reply: reply, recorder: recorder)
        let facts = try await api.setTimeZone(automatic: true, identifier: "Asia/Ho_Chi_Minh")
        try await api.setNotifications(false, bot: "cho-ua")
        let enabled = try await api.notificationsEnabled(bot: "cho-ua")
        let calls = recorder.calls
        #expect(facts == SettingsWire.AboutYou(name: "", timezone: "Asia/Ho_Chi_Minh", timezoneAuto: true))
        #expect(calls[0].0 == "bot_mode.about_you.set")
        #expect(calls[0].1?["timezone_auto"] == true)
        #expect(calls[0].1?["timezone"] == "Asia/Ho_Chi_Minh")
        #expect(calls[0].1?["profile"] == "default")
        #expect(calls[1].0 == "config.set")
        #expect(calls[1].1?["key"] == "bot_mode.notifications")
        #expect(calls[1].1?["value"] == "off")
        #expect(calls[1].1?["profile"] == "cho-ua")
        #expect(calls[2].0 == "config.get")
        #expect(calls[2].1?["profile"] == "cho-ua")
        #expect(!enabled)
    }

    @Test func sharedMetricsNeverSendsWithoutCollection() async throws {
        let recorder = Recorder()
        let api = Self.api(profile: nil, reply: ["enabled": false, "send": false, "decided": true], recorder: recorder)
        _ = try await api.setSharedMetrics(enabled: false, send: true)
        let params = recorder.calls[0].1
        #expect(params?["send"] == false)
        #expect(params?["profile"] == nil)
    }

    @Test func vaultAddSendsSecretsOnlyInsideTheSecretObject() async throws {
        let recorder = Recorder()
        let api = Self.api(reply: ["id": "v1"], recorder: recorder)
        try await api.addVaultLogin(VaultLoginDraft(label: " Shop ", website: "shop.example.com", identifier: "me@example.com", password: "hunter2"))
        let params = try #require(recorder.calls[0].1)
        #expect(params["kind"] == "login")
        #expect(params["label"] == "Shop")
        #expect(params["origin"] == "https://shop.example.com")
        #expect(params["secret"]?["password"] == "hunter2")
        #expect(params["secret"]?["identifier_type"] == "email")
        #expect(params["password"] == nil)
    }

    @Test func incompleteVaultDraftNeverReachesTheWire() async {
        let recorder = Recorder()
        let api = Self.api(reply: ["id": "v1"], recorder: recorder)
        await #expect(throws: SettingsFailure.rejected(code: "incomplete")) {
            try await api.addVaultLogin(VaultLoginDraft(label: "Shop"))
        }
        #expect(recorder.calls.isEmpty)
    }

    @Test func malformedReplyBecomesAnUnexpectedFailure() async {
        let recorder = Recorder()
        let api = Self.api(reply: ["subscriptions": "nope"], recorder: recorder)
        await #expect(throws: SettingsFailure.unexpected) { _ = try await api.subscriptions(refresh: true) }
    }

    @Test func subscriptionsRefreshFlagTravels() async throws {
        let recorder = Recorder()
        let api = Self.api(reply: ["subscriptions": []], recorder: recorder)
        _ = try await api.subscriptions(refresh: true)
        #expect(recorder.calls[0].1?["refresh"] == true)
    }
}
