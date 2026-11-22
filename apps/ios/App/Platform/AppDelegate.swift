import Foundation
import PalClient

#if os(iOS)
import UIKit

@MainActor
enum PlatformApplication {
    static func registerForRemoteNotifications() {
        UIApplication.shared.registerForRemoteNotifications()
    }

    static let didBecomeActive = UIApplication.didBecomeActiveNotification

    static func followActivity(of presence: ReachPresence) {}
}

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    let push = PushNotifications()

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { await push.didRegister(deviceToken: deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        push.didFailToRegister(error)
    }
}
#elseif os(macOS)
import AppKit

@MainActor
enum PlatformApplication {
    static func registerForRemoteNotifications() {
        NSApplication.shared.registerForRemoteNotifications()
    }

    static let didBecomeActive = NSApplication.didBecomeActiveNotification

    private static let activity = MacAppActivity()

    static func followActivity(of presence: ReachPresence) {
        activity.follow(presence)
    }
}

enum TestHostMode {
    static let isActive: Bool = {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            && environment["XCTestBundlePath"].map { URL(filePath: $0).lastPathComponent == "HermesBotsTests.xctest" } == true
    }()
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let push: PushNotifications
    let updater: AppUpdater?

    override init() {
        let push = PushNotifications()
        self.push = push
        updater = TestHostMode.isActive ? nil : AppUpdater.make(notices: push)
        if TestHostMode.isActive { NSApplication.shared.setActivationPolicy(.prohibited) }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        updater?.start()
    }

    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { await push.didRegister(deviceToken: deviceToken) }
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        push.didFailToRegister(error)
    }
}
#endif
