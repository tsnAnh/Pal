import PalAuth
import Foundation

#if os(iOS)
import UIKit
#endif

enum DeviceInfo {
    @MainActor
    static var formFactor: DeviceFormFactor {
        #if os(iOS)
        switch UIDevice.current.userInterfaceIdiom {
        case .phone: .phone
        case .pad: .pad
        default: .other
        }
        #elseif os(macOS)
        .mac
        #endif
    }

    @MainActor
    static var systemName: String {
        #if os(iOS)
        UIDevice.current.systemName
        #elseif os(macOS)
        "macOS"
        #endif
    }

    @MainActor
    static var systemVersion: String {
        #if os(iOS)
        UIDevice.current.systemVersion
        #elseif os(macOS)
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        #endif
    }

    @MainActor
    static var model: String {
        #if os(iOS)
        UIDevice.current.model
        #elseif os(macOS)
        hardwareIdentifier
        #endif
    }

    @MainActor
    static var osDescription: String {
        #if os(iOS)
        "iOS \(systemVersion)"
        #elseif os(macOS)
        "macOS \(systemVersion)"
        #endif
    }

    static var hardwareIdentifier: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        #if os(macOS)
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buffer = [UInt8](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        #else
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
        #endif
    }
}
