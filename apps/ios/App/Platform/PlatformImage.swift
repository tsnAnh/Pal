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

    func roundedIcon(points: CGFloat) -> PlatformImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: points, height: points), format: .preferred())
        return renderer.image { _ in
            let rect = CGRect(x: 0, y: 0, width: points, height: points)
            UIBezierPath(roundedRect: rect, cornerRadius: points * 0.22).addClip()
            draw(in: rect)
        }
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

    func roundedIcon(points: CGFloat) -> NSImage {
        let size = NSSize(width: points, height: points)
        return NSImage(size: size, flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: points * 0.22, yRadius: points * 0.22).addClip()
            self.draw(in: rect)
            return true
        }
    }
}
#endif
