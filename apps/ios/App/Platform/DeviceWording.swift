import Foundation
import PalProtocol

enum DeviceWording {
    static var copyToDevice: String {
        PlatformVariant.pick(mac: String(localized: "Copy to Mac"), iOS: String(localized: "Copy to Phone"))
    }

    static var pasteFromDevice: String {
        PlatformVariant.pick(mac: String(localized: "Paste from Mac"), iOS: String(localized: "Paste from Phone"))
    }

    static var copiedToDevice: String {
        PlatformVariant.pick(mac: String(localized: "Copied to Mac"), iOS: String(localized: "Copied to phone"))
    }

    static var deviceSystemImage: String {
        PlatformVariant.pick(mac: "laptopcomputer", iOS: "iphone")
    }
}

enum PlatformCapabilities {
    static var hasTouchScreen: Bool {
        PlatformVariant.pick(mac: false, iOS: true)
    }
}
