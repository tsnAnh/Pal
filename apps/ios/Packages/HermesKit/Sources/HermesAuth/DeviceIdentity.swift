import Foundation
import HermesDiagnostics
import Security
import Synchronization

public enum DeviceFormFactor: Sendable, Equatable {
    case phone
    case pad
    case other

    public var label: String {
        switch self {
        case .phone: "iPhone"
        case .pad: "iPad"
        case .other: "iOS device"
        }
    }
}

public struct DeviceIdentity: Sendable, Equatable {
    public static let kind = "ios"
    public static let maximumLabelLength = 40
    public static let maximumVersionLength = 32
    public static let maximumHardwareLength = 40

    public let deviceID: String
    public let label: String
    public let appVersion: String
    public let model: String
    public let os: String

    public init(deviceID: String, formFactor: DeviceFormFactor, appVersion: String, model: String = "", os: String = "") {
        self.deviceID = deviceID
        self.label = formFactor.label
        self.appVersion = String(appVersion.prefix(Self.maximumVersionLength))
        self.model = String(model.prefix(Self.maximumHardwareLength))
        self.os = String(os.prefix(Self.maximumHardwareLength))
    }

    public static func isValid(deviceID: String) -> Bool {
        guard (8...64).contains(deviceID.utf8.count) else { return false }
        return deviceID.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || byte == 45
        }
    }

    public static func appVersion(of bundle: Bundle) -> String {
        let info = bundle.infoDictionary
        let marketing = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        switch (marketing.isEmpty, build.isEmpty) {
        case (false, false): return "\(marketing) (\(build))"
        case (false, true): return marketing
        case (true, false): return build
        case (true, true): return ""
        }
    }

    public static func resolve(
        store: any DeviceIDStore,
        formFactor: DeviceFormFactor,
        appVersion: String,
        model: String = "",
        os: String = "",
        diagnostics: Diagnostics = .silent
    ) -> DeviceIdentity {
        let deviceID: String
        do {
            if let stored = try store.load(), isValid(deviceID: stored) {
                deviceID = stored
            } else {
                deviceID = UUID().uuidString
                try store.save(deviceID)
            }
        } catch {
            diagnostics.warning("reach", "device id not persisted: \(Diagnostics.describe(error))")
            return DeviceIdentity(deviceID: UUID().uuidString, formFactor: formFactor, appVersion: appVersion, model: model, os: os)
        }
        return DeviceIdentity(deviceID: deviceID, formFactor: formFactor, appVersion: appVersion, model: model, os: os)
    }
}

public protocol DeviceIDStore: Sendable {
    func load() throws -> String?
    func save(_ deviceID: String) throws
}

public final class InMemoryDeviceIDStore: DeviceIDStore {
    private let value = Mutex<String?>(nil)

    public init(_ initial: String? = nil) {
        value.withLock { $0 = initial }
    }

    public func load() throws -> String? { value.withLock { $0 } }
    public func save(_ deviceID: String) throws { value.withLock { $0 = deviceID } }
}

public struct KeychainDeviceIDStore: DeviceIDStore {
    public let service: String
    public let account: String

    public init(service: String = "dev.tsnanh.hermes.bot.device", account: String = "device-id") {
        self.service = service
        self.account = account
    }

    private var identity: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }

    public func load() throws -> String? {
        var query = identity
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
        guard let data = item as? Data, let text = String(data: data, encoding: .utf8) else { throw KeychainError.corruptItem }
        return text
    }

    public func save(_ deviceID: String) throws {
        let data = Data(deviceID.utf8)
        let updateStatus = SecItemUpdate(
            identity as CFDictionary,
            [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw KeychainError.status(updateStatus) }
        var attributes = identity
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError.status(addStatus) }
    }
}
