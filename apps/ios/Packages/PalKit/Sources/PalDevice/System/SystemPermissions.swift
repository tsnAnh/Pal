import Contacts
import CoreLocation
import EventKit
import Foundation
import PalProtocol
#if canImport(AlarmKit) && os(iOS)
import AlarmKit
#endif
#if canImport(HomeKit) && os(iOS)
import HomeKit
#endif

public struct SystemPermissions: DevicePermissions {
    public init() {}

    public func status(of connector: DeviceConnectorID) async -> DeviceOSPermission {
        switch connector {
        case .calendar: Self.map(EKEventStore.authorizationStatus(for: .event))
        case .reminders: Self.map(EKEventStore.authorizationStatus(for: .reminder))
        case .contacts: Self.map(CNContactStore.authorizationStatus(for: .contacts))
        case .location: Self.map(await LocationService.shared.authorizationStatus)
        case .alarms: Self.alarmsStatus()
        case .home: await Self.homeStatus()
        case .shell, .files: Self.localAccessStatus
        case .input: AccessibilityAccess.status
        }
    }

    public func request(_ connector: DeviceConnectorID) async -> DeviceOSPermission {
        switch connector {
        case .calendar:
            _ = try? await EKEventStore().requestFullAccessToEvents()
        case .reminders:
            _ = try? await EKEventStore().requestFullAccessToReminders()
        case .contacts:
            _ = try? await CNContactStore().requestAccess(for: .contacts)
        case .location:
            _ = await LocationService.shared.requestAuthorization()
        case .alarms:
            await Self.requestAlarms()
        case .home:
            await Self.requestHome()
        case .shell, .files:
            break
        case .input:
            AccessibilityAccess.request()
        }
        return await status(of: connector)
    }

    private static var localAccessStatus: DeviceOSPermission {
        #if os(macOS)
        .granted
        #else
        .unsupported
        #endif
    }

    static func map(_ status: EKAuthorizationStatus) -> DeviceOSPermission {
        switch status {
        case .fullAccess: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    static func map(_ status: CNAuthorizationStatus) -> DeviceOSPermission {
        switch status {
        case .authorized, .limited: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    static func map(_ status: CLAuthorizationStatus) -> DeviceOSPermission {
        switch status {
        case .authorizedAlways, .authorizedWhenInUse: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    private static func alarmsStatus() -> DeviceOSPermission {
        #if canImport(AlarmKit) && os(iOS)
        switch AlarmManager.shared.authorizationState {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        case .denied: .denied
        @unknown default: .denied
        }
        #else
        .unsupported
        #endif
    }

    private static func requestAlarms() async {
        #if canImport(AlarmKit) && os(iOS)
        _ = try? await AlarmManager.shared.requestAuthorization()
        #endif
    }

    private static func homeStatus() async -> DeviceOSPermission {
        #if canImport(HomeKit) && os(iOS)
        guard let status = await HomeService.shared.authorization else { return .notDetermined }
        if status.contains(.authorized) { return .granted }
        if status.contains(.restricted) { return .denied }
        return status.contains(.determined) ? .denied : .notDetermined
        #else
        .unsupported
        #endif
    }

    private static func requestHome() async {
        #if canImport(HomeKit) && os(iOS)
        _ = await HomeService.shared.prepare()
        #endif
    }
}

extension DeviceProviders {
    public static func system() -> DeviceProviders {
        #if canImport(AlarmKit) && os(iOS)
        let alarms: (any AlarmsProviding)? = SystemAlarms()
        #else
        let alarms: (any AlarmsProviding)? = nil
        #endif
        #if canImport(HomeKit) && os(iOS)
        let home: (any HomeProviding)? = SystemHome()
        #else
        let home: (any HomeProviding)? = nil
        #endif
        #if os(macOS)
        let shell: (any ShellProviding)? = SystemShell()
        let files: (any FilesProviding)? = SystemFiles()
        let input: (any InputProviding)? = InputController.shared
        #else
        let shell: (any ShellProviding)? = nil
        let files: (any FilesProviding)? = nil
        let input: (any InputProviding)? = nil
        #endif
        return DeviceProviders(
            calendar: EventKitCalendar(), reminders: EventKitReminders(), contacts: SystemContacts(),
            location: SystemLocation(), alarms: alarms, home: home, shell: shell, files: files, input: input
        )
    }
}
