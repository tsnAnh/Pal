import Contacts
#if os(macOS)
import CoreGraphics
#endif
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
        case .apps: Self.appsStatus
        case .clipboard: Self.clipboardStatus
        case .screen: Self.screenStatus()
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
        case .apps:
            Self.requestApps()
        case .clipboard:
            break
        case .screen:
            Self.requestScreen()
        }
        return await status(of: connector)
    }

    private static let appsAskedKey = "dev.tsnanh.pal.apps-permissions-asked"

    private static var appsStatus: DeviceOSPermission {
        #if os(macOS)
        if AppsSystemAccess.screenRecordingGranted, AppsSystemAccess.accessibilityGranted { return .granted }
        return UserDefaults.standard.bool(forKey: appsAskedKey) ? .denied : .notDetermined
        #else
        .unsupported
        #endif
    }

    private static func requestApps() {
        #if os(macOS)
        UserDefaults.standard.set(true, forKey: appsAskedKey)
        AppsSystemAccess.requestScreenRecording()
        AppsSystemAccess.requestAccessibility()
        #endif
    }

    private static let screenRequestedKey = "dev.tsnanh.hermes.screen-recording-requested"

    private static func screenStatus() -> DeviceOSPermission {
        #if os(macOS)
        if CGPreflightScreenCaptureAccess() { return .granted }
        return UserDefaults.standard.bool(forKey: screenRequestedKey) ? .denied : .notDetermined
        #else
        .unsupported
        #endif
    }

    private static func requestScreen() {
        #if os(macOS)
        UserDefaults.standard.set(true, forKey: screenRequestedKey)
        _ = CGRequestScreenCaptureAccess()
        #endif
    }

    private static var localAccessStatus: DeviceOSPermission {
        #if os(macOS)
        .granted
        #else
        .unsupported
        #endif
    }

    private static var clipboardStatus: DeviceOSPermission {
        #if os(macOS)
        GeneralPasteboard().accessAllowed ? .granted : .denied
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
    public static func system(screenActivity: @escaping @Sendable (Bool) -> Void = { _ in }) -> DeviceProviders {
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
        let apps: (any AppsProviding)? = AppsController(workspace: SystemAppsWorkspace())
        let clipboard: (any ClipboardProviding)? = SystemClipboard(store: GeneralPasteboard())
        let screen: (any ScreenProviding)? = GuardedScreen(source: SystemScreenSource(), activity: screenActivity)
        #else
        let shell: (any ShellProviding)? = nil
        let files: (any FilesProviding)? = nil
        let apps: (any AppsProviding)? = nil
        let clipboard: (any ClipboardProviding)? = nil
        let screen: (any ScreenProviding)? = nil
        #endif
        return DeviceProviders(
            calendar: EventKitCalendar(), reminders: EventKitReminders(), contacts: SystemContacts(),
            location: SystemLocation(), alarms: alarms, home: home, shell: shell, files: files, apps: apps,
            clipboard: clipboard, screen: screen
        )
    }
}
