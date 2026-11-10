import Foundation

#if os(iOS)
import UIKit

@MainActor
enum PlatformApplication {
    static func registerForRemoteNotifications() {
        UIApplication.shared.registerForRemoteNotifications()
    }
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
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let push = PushNotifications()

    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { await push.didRegister(deviceToken: deviceToken) }
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        push.didFailToRegister(error)
    }
}
#endif
