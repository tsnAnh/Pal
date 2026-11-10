import HermesAuth
import HermesSettings
import Observation
import SwiftUI
import UserNotifications

enum AppVersion {
    static var display: String { DeviceIdentity.appVersion(of: .main) }
}

enum TimeZoneNames {
    static func display(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: " ")
    }
}

enum LanguageName {
    static let current = "System"
}

extension ConnectionModel {
    var gatewayHost: String {
        let host = URL(string: baseURLText)?.host(percentEncoded: false)
        return host ?? baseURLText
    }
}

enum FeedbackReport {
    @MainActor
    static func text(connection: ConnectionModel) -> String {
        return """
        Pal feedback

        App: \(AppVersion.display)
        System: \(DeviceInfo.systemName) \(DeviceInfo.systemVersion)
        Device: \(DeviceInfo.model)

        What happened:

        """
    }
}

@MainActor
@Observable
final class SystemNotifications {
    private(set) var status: UNAuthorizationStatus = .notDetermined
    private(set) var preferenceOn: Bool
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        preferenceOn = defaults.object(forKey: SettingsDefaults.pushKey) as? Bool ?? true
    }

    var isAuthorized: Bool {
        switch status {
        case .authorized, .provisional, .ephemeral: true
        default: false
        }
    }

    var isOn: Bool { preferenceOn && isAuthorized }

    func refresh() async {
        status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func set(_ enabled: Bool, hub: SettingsHub, openSettings: () -> Void) async {
        if enabled {
            await enable(openSettings: openSettings)
        } else {
            await disable(hub: hub)
        }
    }

    private func enable(openSettings: () -> Void) async {
        await refresh()
        switch status {
        case .notDetermined:
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
            await refresh()
        case .denied:
            remember(true)
            openSettings()
            return
        default:
            break
        }
        remember(isAuthorized)
    }

    private func disable(hub: SettingsHub) async {
        remember(false)
        guard let deviceID = hub.connection.localDeviceID else { return }
        do {
            _ = try await hub.connection.rpc("push.unregister", ["device_id": .string(deviceID)])
        } catch {
            remember(true)
            hub.message = SettingsFailure(error).message
        }
    }

    private func remember(_ value: Bool) {
        preferenceOn = value
        defaults.set(value, forKey: SettingsDefaults.pushKey)
    }
}
