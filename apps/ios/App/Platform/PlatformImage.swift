import ImageIO
import SwiftUI

#if os(iOS)
import UIKit

typealias PlatformImage = UIImage

extension Image {
    init(platformImage: PlatformImage) {
        self.init(uiImage: platformImage)
    }
}

extension PlatformImage {
    static func thumbnail(from data: Data, side: CGFloat) async -> PlatformImage? {
        await UIImage(data: data)?.byPreparingThumbnail(ofSize: CGSize(width: side, height: side))
    }

    static func icon(_ image: CGImage, scale: CGFloat) -> UIImage {
        UIImage(cgImage: image, scale: scale, orientation: .up)
    }

    static func iconMask(_ rect: CGRect, radius: CGFloat) -> CGPath {
        UIBezierPath(roundedRect: rect, cornerRadius: radius).cgPath
    }
}
#elseif os(macOS)
import AppKit

typealias PlatformImage = NSImage

extension Image {
    init(platformImage: PlatformImage) {
        self.init(nsImage: platformImage)
    }
}

extension NSImage {
    convenience init(cgImage: CGImage) {
        self.init(cgImage: cgImage, size: .zero)
    }

    func jpegData(compressionQuality: CGFloat) -> Data? {
        bitmap?.representation(using: .jpeg, properties: [.compressionFactor: compressionQuality])
    }

    func pngData() -> Data? {
        bitmap?.representation(using: .png, properties: [:])
    }

    private var bitmap: NSBitmapImageRep? {
        guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cgImage)
    }

    static func thumbnail(from data: Data, side: CGFloat) async -> NSImage? {
        let scale = await MainActor.run { NSScreen.main?.backingScaleFactor ?? 2 }
        return await Task.detached(priority: .utility) { () -> NSImage? in
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: side * scale,
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return NSImage(cgImage: cgImage, size: NSSize(width: CGFloat(cgImage.width) / scale, height: CGFloat(cgImage.height) / scale))
        }.value
    }

    static func icon(_ image: CGImage, scale: CGFloat) -> NSImage {
        NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale))
    }

    static func iconMask(_ rect: CGRect, radius: CGFloat) -> CGPath {
        CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }
}
#endif

extension CGImage {
    func roundedIcon(points: CGFloat, scale: CGFloat) -> PlatformImage? {
        let side = Int((points * scale).rounded())
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        let rect = CGRect(x: 0, y: 0, width: side, height: side)
        context.addPath(PlatformImage.iconMask(rect, radius: CGFloat(side) * 0.22))
        context.clip()
        context.interpolationQuality = .high
        context.draw(self, in: rect)
        return context.makeImage().map { PlatformImage.icon($0, scale: scale) }
    }
}
