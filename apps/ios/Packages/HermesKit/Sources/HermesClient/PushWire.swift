import Foundation
import HermesProtocol

public enum PushEnvironment: String, Sendable, Equatable {
    case sandbox
    case production
}

public struct PushToken: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    static let byteRange = 16...100

    let hex: String

    public init?(deviceToken: Data) {
        guard Self.byteRange.contains(deviceToken.count) else { return nil }
        hex = deviceToken.map { String(format: "%02x", $0) }.joined()
    }

    public var description: String { "PushToken(redacted)" }
    public var debugDescription: String { description }
}

public struct PushRegistration: Sendable, Equatable, CustomStringConvertible {
    public let token: PushToken
    public let environment: PushEnvironment
    public let bundleID: String

    public init?(token: PushToken, environment: PushEnvironment, bundleID: String) {
        guard PushWire.isValid(bundleID: bundleID) else { return nil }
        self.token = token
        self.environment = environment
        self.bundleID = bundleID
    }

    public var description: String { "PushRegistration(\(environment.rawValue), \(bundleID), \(token))" }
}

public enum PushWire {
    public static func isValid(bundleID: String) -> Bool {
        guard (3...155).contains(bundleID.utf8.count) else { return false }
        return bundleID.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || byte == 46 || byte == 45
        }
    }

    public static func registerParams(deviceID: String, registration: PushRegistration) -> JSONValue {
        [
            "device_id": .string(deviceID),
            "apns_token": .string(registration.token.hex),
            "environment": .string(registration.environment.rawValue),
            "bundle_id": .string(registration.bundleID),
        ]
    }

    public static func unregisterParams(deviceID: String) -> JSONValue {
        ["device_id": .string(deviceID)]
    }
}
