import Foundation
import HermesProtocol
import HermesSettings
import Observation
import SwiftUI

enum SettingsRoute: Hashable {
    case account
    case usage
    case vault
    case permissions
    case timeZone
    case botComputer
    case devices
    case hermesService
    case modelProviders
    case speechMemory
    case importMemory
    case botNotifications
    case appearance
    case haptics
    case dataSharing
}

enum Loadable<Value> {
    case loading
    case loaded(Value)
    case failed(String)

    var value: Value? {
        if case .loaded(let value) = self { value } else { nil }
    }
}

enum SettingsDefaults {
    static let hapticsKey = "hermesHapticsEnabled"
    static let pushKey = "hermesPushEnabled"
}

@MainActor
@Observable
final class SettingsHub {
    let connection: ConnectionModel
    let roster: RosterModel

    private(set) var usageHeadline: String?
    private(set) var usageOverview: UsageOverview?
    private var usageDismissals = 0
    private var lastUsageRefresh: Date?
    private(set) var permissions: PermissionsSummary?
    private(set) var aboutYou: SettingsWire.AboutYou?
    var message: String?

    init(connection: ConnectionModel, roster: RosterModel) {
        self.connection = connection
        self.roster = roster
    }

    var api: SettingsAPI {
        SettingsAPI(profile: roster.bots.first(where: \.isDefault)?.name) { [connection] method, params in
            try await connection.rpc(method, params)
        }
    }

    var deviceTimeZone: String { TimeZone.current.identifier }

    var timeZoneIsAutomatic: Bool { aboutYou?.timezoneAuto ?? false }

    var timeZoneDisplay: String {
        let identifier = timeZoneIsAutomatic ? deviceTimeZone : (aboutYou?.timezone ?? "")
        return identifier.isEmpty ? deviceTimeZone : identifier
    }

    var usageNotice: UsageNotice? {
        _ = usageDismissals
        return UsageNoticeStore(account: connection.accountKey).visible(usageOverview.flatMap(UsageNotice.init))
    }

    func dismissUsageNotice() {
        guard let notice = usageNotice else { return }
        UsageNoticeStore(account: connection.accountKey).dismiss(notice)
        usageDismissals += 1
    }

    func refreshUsageIfStale(maxAge: TimeInterval = 300) async {
        if let last = lastUsageRefresh, Date().timeIntervalSince(last) < maxAge { return }
        await refreshUsageHeadline()
    }

    func refresh() async {
        async let headline: Void = refreshUsageHeadline()
        async let state: Void = refreshAccountState()
        _ = await (headline, state)
    }

    private func refreshUsageHeadline() async {
        let subscriptions = try? await api.subscriptions(refresh: true)
        lastUsageRefresh = Date()
        usageOverview = subscriptions.map(UsageOverview.init)
        usageHeadline = usageOverview?.headlineText
    }

    private func refreshAccountState() async {
        let api = api
        async let permissions = try? api.permissions()
        async let facts = try? api.aboutYou()
        let (permissionState, aboutYou) = await (permissions, facts)
        self.permissions = permissionState.map(PermissionsSummary.init)
        self.aboutYou = aboutYou
        await keepTimeZoneInStep()
    }

    func setTimeZoneAutomatic(_ enabled: Bool) async {
        let previous = aboutYou
        aboutYou = SettingsWire.AboutYou(
            name: previous?.name ?? "", timezone: enabled ? deviceTimeZone : (previous?.timezone ?? deviceTimeZone),
            timezoneAuto: enabled
        )
        do {
            aboutYou = try await api.setTimeZone(automatic: enabled, identifier: enabled ? deviceTimeZone : nil)
        } catch {
            aboutYou = previous
            message = SettingsFailure(error).message
        }
    }

    func setTimeZone(_ identifier: String) async {
        let previous = aboutYou
        do {
            aboutYou = try await api.setTimeZone(automatic: false, identifier: identifier)
        } catch {
            aboutYou = previous
            message = SettingsFailure(error).message
        }
    }

    func updatePermissions(_ summary: PermissionsSummary) {
        permissions = summary
    }

    private func keepTimeZoneInStep() async {
        guard let facts = aboutYou, facts.timezoneAuto, facts.timezone != deviceTimeZone else { return }
        if let updated = try? await api.setTimeZone(automatic: true, identifier: deviceTimeZone) { aboutYou = updated }
    }
}
