import CoreGraphics
import Foundation
import ImageIO

public enum AvatarPhoto {
    public static let maximumSourceBytes = 15_000_000
    public static let maximumUploadBytes = 2_000_000
    public static let edge = 256

    public enum Failure: Error, Equatable, Sendable {
        case tooLarge
        case unsupported
        case unreadable
    }

    static let acceptedTypes: Set<String> = [
        "public.png", "public.jpeg", "org.webmproject.webp", "com.compuserve.gif", "public.heic",
    ]

    public static func prepare(_ source: Data) throws -> Data {
        guard source.count <= maximumSourceBytes else { throw Failure.tooLarge }
        guard let imageSource = CGImageSourceCreateWithData(source as CFData, nil),
              CGImageSourceGetCount(imageSource) > 0,
              let type = CGImageSourceGetType(imageSource) as String?
        else { throw Failure.unsupported }
        guard acceptedTypes.contains(type) else { throw Failure.unsupported }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: edge * 2,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary),
              let square = squareCrop(thumbnail),
              let png = encodedPNG(square)
        else { throw Failure.unreadable }
        guard png.count <= maximumUploadBytes else { throw Failure.tooLarge }
        return png
    }

    private static func squareCrop(_ image: CGImage) -> CGImage? {
        let side = min(image.width, image.height)
        let origin = CGPoint(x: (image.width - side) / 2, y: (image.height - side) / 2)
        guard let cropped = image.cropping(to: CGRect(origin: origin, size: CGSize(width: side, height: side))),
              let context = CGContext(
                  data: nil, width: edge, height: edge, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: edge, height: edge))
        return context.makeImage()
    }

    private static func encodedPNG(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
