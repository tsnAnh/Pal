import CoreGraphics
import Foundation

public struct RFBSize: Equatable, Sendable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public struct RFBRect: Equatable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public enum RFBVersion: Sendable, Equatable {
    case v37
    case v38

    public var banner: String {
        switch self {
        case .v37: "RFB 003.007\n"
        case .v38: "RFB 003.008\n"
        }
    }

    init?(banner: [UInt8]) {
        switch String(decoding: banner, as: UTF8.self) {
        case Self.v37.banner: self = .v37
        case Self.v38.banner: self = .v38
        default: return nil
        }
    }
}

public enum RFBPixelFormat: Sendable {
    case bgrx

    public var encoded: [UInt8] {
        [32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0]
    }
}

public enum RFBFailure: Error, Equatable, Sendable {
    case unsupportedVersion
    case unsupportedSecurity
    case securityRefused
    case invalidServerInit
    case rectangleOutOfBounds
    case unsupportedEncoding(Int32)
    case unsupportedMessage(UInt8)
    case clipboardTooLarge
}

public enum RFBEvent: Equatable, Sendable {
    case ready(RFBSize, name: String)
    case updated([RFBRect])
    case resized(RFBSize)
    case bell
    case serverCutText(String)
}

public struct RFBStep: Equatable, Sendable {
    public var replies: [Data] = []
    public var events: [RFBEvent] = []
}

public struct RFBFramebuffer: Equatable, Sendable {
    public static let maximumDimension = 16384
    static let bytesPerPixel = 4

    public private(set) var size: RFBSize
    public private(set) var pixels: Data

    public init(size: RFBSize) {
        self.size = size
        pixels = Data(count: size.width * size.height * Self.bytesPerPixel)
    }

    public func pixel(x: Int, y: Int) -> [UInt8] {
        let offset = (y * size.width + x) * Self.bytesPerPixel
        return Array(pixels[pixels.startIndex + offset ..< pixels.startIndex + offset + Self.bytesPerPixel])
    }

    func contains(_ rect: RFBRect) -> Bool {
        rect.x >= 0 && rect.y >= 0 && rect.width >= 0 && rect.height >= 0
            && rect.x + rect.width <= size.width && rect.y + rect.height <= size.height
    }

    mutating func paint(_ rect: RFBRect, from source: [UInt8], at offset: Int) {
        let rowBytes = rect.width * Self.bytesPerPixel
        let stride = size.width * Self.bytesPerPixel
        pixels.withUnsafeMutableBytes { destination in
            source.withUnsafeBytes { bytes in
                for row in 0..<rect.height {
                    let from = offset + row * rowBytes
                    let to = (rect.y + row) * stride + rect.x * Self.bytesPerPixel
                    destination.baseAddress!.advanced(by: to).copyMemory(from: bytes.baseAddress!.advanced(by: from), byteCount: rowBytes)
                }
            }
        }
    }

    mutating func copy(_ rect: RFBRect, fromX sourceX: Int, y sourceY: Int) {
        let rowBytes = rect.width * Self.bytesPerPixel
        let stride = size.width * Self.bytesPerPixel
        pixels.withUnsafeMutableBytes { buffer in
            let base = buffer.baseAddress!
            let rows = sourceY < rect.y ? Array((0..<rect.height).reversed()) : Array(0..<rect.height)
            for row in rows {
                let from = (sourceY + row) * stride + sourceX * Self.bytesPerPixel
                let to = (rect.y + row) * stride + rect.x * Self.bytesPerPixel
                memmove(base.advanced(by: to), base.advanced(by: from), rowBytes)
            }
        }
    }

    public func makeImage() -> CGImage? {
        guard size.width > 0, size.height > 0,
              let provider = CGDataProvider(data: pixels as CFData)
        else { return nil }
        let bitmap = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
        return CGImage(
            width: size.width,
            height: size.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: size.width * Self.bytesPerPixel,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: bitmap),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    mutating func resize(to newSize: RFBSize) {
        self = RFBFramebuffer(size: newSize)
    }
}
