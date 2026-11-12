import Foundation
import PalProtocol

enum DeviceWording {
    static var copyToDevice: String {
        #if os(iOS)
        String(localized: "Copy to Phone")
        #else
        String(localized: "Copy to Mac")
        #endif
    }

    static var pasteFromDevice: String {
        #if os(iOS)
        String(localized: "Paste from Phone")
        #else
        String(localized: "Paste from Mac")
        #endif
    }

    static var copiedToDevice: String {
        #if os(iOS)
        String(localized: "Copied to phone")
        #else
        String(localized: "Copied to Mac")
        #endif
    }

    static var deviceSystemImage: String {
        #if os(iOS)
        "iphone"
        #else
        "laptopcomputer"
        #endif
    }
}

enum PlatformCapabilities {
    static var deviceConnectors: [DeviceConnectorID] {
        #if os(iOS)
        [.calendar, .home, .reminders, .contacts, .location, .alarms]
        #else
        [.calendar, .reminders, .contacts, .location, .shell, .files, .clipboard]
        #endif
    }

    static var hasTouchScreen: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }
}
