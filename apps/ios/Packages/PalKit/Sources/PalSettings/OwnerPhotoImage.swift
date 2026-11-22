import CoreGraphics
import Foundation
import ImageIO

public enum OwnerPhotoImage {
    public static let maximumSourceBytes = 10_000_000
    public static let maximumUploadBytes = 2_000_000
    public static let edge = 512
    public static let jpegQuality = 0.85
    public static let workingPixels = 2048

    public enum Failure: Error, Equatable, Sendable {
        case tooLarge
        case unsupported
        case unreadable
    }

    static let acceptedTypes: Set<String> = ["public.png", "public.jpeg", "public.heic", "public.heif"]

    public static func decode(contentsOf url: URL) throws -> CGImage {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { throw Failure.unreadable }
        guard size <= maximumSourceBytes else { throw Failure.tooLarge }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { throw Failure.unreadable }
        return try decode(data)
    }

    public static func decode(_ source: Data) throws -> CGImage {
        guard source.count <= maximumSourceBytes else { throw Failure.tooLarge }
        guard let imageSource = CGImageSourceCreateWithData(source as CFData, nil),
              CGImageSourceGetCount(imageSource) > 0,
              let type = CGImageSourceGetType(imageSource) as String?,
              acceptedTypes.contains(type)
        else { throw Failure.unsupported }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: workingPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary),
              image.width > 0, image.height > 0
        else { throw Failure.unreadable }
        return image
    }

    public static func jpeg(cropping image: CGImage, to crop: PhotoCrop) throws -> Data {
        let size = CGSize(width: image.width, height: image.height)
        let rect = crop.sourceRect(in: size)
        let scale = CGFloat(edge) / rect.width
        guard let context = CGContext(
            data: nil, width: edge, height: edge, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw Failure.unreadable }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: edge, height: edge))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(
            x: -rect.minX * scale,
            y: -(size.height - rect.maxY) * scale,
            width: size.width * scale,
            height: size.height * scale
        ))
        guard let square = context.makeImage() else { throw Failure.unreadable }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else {
            throw Failure.unreadable
        }
        CGImageDestinationAddImage(
            destination, square, [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { throw Failure.unreadable }
        guard output.length <= maximumUploadBytes else { throw Failure.tooLarge }
        return output as Data
    }
}
