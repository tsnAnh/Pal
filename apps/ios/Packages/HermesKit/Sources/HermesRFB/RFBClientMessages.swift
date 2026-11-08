import Foundation

public enum RFBButtons {
    public static let left: UInt8 = 1
    public static let middle: UInt8 = 2
    public static let right: UInt8 = 4
    public static let scrollUp: UInt8 = 8
    public static let scrollDown: UInt8 = 16
    public static let scrollLeft: UInt8 = 32
    public static let scrollRight: UInt8 = 64
}

public enum RFBKeysym {
    public static let backspace: UInt32 = 0xFF08
    public static let tab: UInt32 = 0xFF09
    public static let returnKey: UInt32 = 0xFF0D
    public static let escape: UInt32 = 0xFF1B
    public static let delete: UInt32 = 0xFFFF
    public static let left: UInt32 = 0xFF51
    public static let up: UInt32 = 0xFF52
    public static let right: UInt32 = 0xFF53
    public static let down: UInt32 = 0xFF54

    public static func forScalar(_ scalar: Unicode.Scalar) -> UInt32 {
        switch scalar.value {
        case 0x0A, 0x0D: returnKey
        case 0x09: tab
        case 0x20...0x7E, 0xA0...0xFF: scalar.value
        default: 0x0100_0000 + scalar.value
        }
    }
}

public enum RFBClientMessages {
    public static let encodingRaw: Int32 = 0
    public static let encodingCopyRect: Int32 = 1
    public static let encodingDesktopSize: Int32 = -223
    public static let maximumClientCutBytes = 256 * 1024 - 1

    public static func version(_ version: RFBVersion) -> Data {
        Data(version.banner.utf8)
    }

    public static let noneSecurityChoice = Data([1])

    public static let sharedClientInit = Data([1])

    public static func setPixelFormat() -> Data {
        var data = Data([0, 0, 0, 0])
        data.append(contentsOf: RFBPixelFormat.bgrx.encoded)
        return data
    }

    public static func setEncodings(_ encodings: [Int32] = [encodingCopyRect, encodingRaw, encodingDesktopSize]) -> Data {
        var data = Data([2, 0])
        data.appendBigEndian(UInt16(encodings.count))
        for encoding in encodings { data.appendBigEndian(UInt32(bitPattern: encoding)) }
        return data
    }

    public static func updateRequest(incremental: Bool, x: Int, y: Int, width: Int, height: Int) -> Data {
        var data = Data([3, incremental ? 1 : 0])
        data.appendBigEndian(clamped16(x))
        data.appendBigEndian(clamped16(y))
        data.appendBigEndian(clamped16(width))
        data.appendBigEndian(clamped16(height))
        return data
    }

    public static func pointer(buttons: UInt8, x: Int, y: Int, within size: RFBSize) -> Data {
        var data = Data([5, buttons])
        data.appendBigEndian(clamped16(min(max(x, 0), size.width - 1)))
        data.appendBigEndian(clamped16(min(max(y, 0), size.height - 1)))
        return data
    }

    public static func key(_ keysym: UInt32, down: Bool) -> Data {
        var data = Data([4, down ? 1 : 0, 0, 0])
        data.appendBigEndian(keysym)
        return data
    }

    public static func clientCutText(_ text: String) -> Data? {
        let scalars = text.unicodeScalars.map { $0.value <= 0xFF ? $0 : "?" }
        let latin1 = Data(scalars.map { UInt8($0.value) })
        guard latin1.count <= maximumClientCutBytes else { return nil }
        var data = Data([6, 0, 0, 0])
        data.appendBigEndian(UInt32(latin1.count))
        data.append(latin1)
        return data
    }

    private static func clamped16(_ value: Int) -> UInt16 {
        UInt16(min(max(value, 0), Int(UInt16.max)))
    }
}

extension Data {
    mutating func appendBigEndian(_ value: UInt16) {
        append(UInt8(value >> 8))
        append(UInt8(value & 0xFF))
    }

    mutating func appendBigEndian(_ value: UInt32) {
        append(UInt8(value >> 24))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }
}
