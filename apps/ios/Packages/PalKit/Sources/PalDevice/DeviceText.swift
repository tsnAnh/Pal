import Foundation

public struct CapturedText: Sendable, Equatable {
    public var text: String
    public var omittedBytes: Int

    public init(text: String = "", omittedBytes: Int = 0) {
        self.text = text
        self.omittedBytes = omittedBytes
    }
}

public enum DeviceTextLimit {
    public static let output = 48 * 1024
    public static let fileContent = 96 * 1024
    public static let clipboardText = 23_000
    public static let clipboardImage = 48 * 1024
    public static let slack = 4
}

public enum TextCap {
    public static func capture(_ bytes: [UInt8], totalBytes: Int, limit: Int) -> CapturedText {
        var cut = min(bytes.count, limit)
        if cut < totalBytes {
            while cut > 0, cut < bytes.count, bytes[cut] & 0xC0 == 0x80 { cut -= 1 }
        }
        return CapturedText(text: String(decoding: bytes[0..<cut], as: UTF8.self), omittedBytes: max(0, totalBytes - cut))
    }

    public static func finish(_ captured: CapturedText, limit: Int) -> (text: String, truncated: Bool) {
        var text = captured.text
        var omitted = captured.omittedBytes
        let bytes = Array(text.utf8)
        if bytes.count > limit {
            var cut = limit
            while cut > 0, bytes[cut] & 0xC0 == 0x80 { cut -= 1 }
            omitted += bytes.count - cut
            text = String(decoding: bytes[0..<cut], as: UTF8.self)
        }
        guard omitted > 0 else { return (text, false) }
        return (text + "\n…[truncated \(omitted) bytes omitted]", true)
    }
}

public enum DevicePath {
    public static func resolve(_ raw: String, home: String = NSHomeDirectory()) throws -> String {
        guard !raw.isEmpty, !raw.utf8.contains(0) else { throw DeviceProviderError.invalidArgs("path is required.") }
        let expanded: String
        if raw == "~" {
            expanded = home
        } else if raw.hasPrefix("~/") {
            expanded = home + "/" + String(raw.dropFirst(2))
        } else if raw.hasPrefix("/") {
            expanded = raw
        } else {
            throw DeviceProviderError.invalidArgs("path must be absolute or start with ~.")
        }
        return URL(fileURLWithPath: expanded).standardized.path
    }
}
