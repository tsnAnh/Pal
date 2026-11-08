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

    func refresh() async {
        let api = api
        async let usage = try? api.subscriptions(refresh: false)
        async let permissions = try? api.permissions()
        async let facts = try? api.aboutYou()
        let (subscriptions, permissionState, aboutYou) = await (usage, permissions, facts)
        usageHeadline = subscriptions.flatMap { UsageOverview($0).headlineText }
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
